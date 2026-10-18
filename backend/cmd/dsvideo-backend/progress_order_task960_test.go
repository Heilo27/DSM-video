package main

// TASK-960 (FRD-001 FR-014, FR-019): the edges of the progress ordering rule that the
// OC-1027/OC-1033 oracle does not reach. The rule (profiles.go, newProgressClock and
// upsertProgress): the later watch wins, ordered by (watch time, write_seq); no watch time
// counts as later than the server's clock; a refused write moves no counter.

import (
	"testing"
	"time"
)

// postProgressAt sends one REST progress write for w1; watchedAt "" omits the field, as an
// older app (or a live write from one) does.
func (e *progressSeqEnv) postProgressAt(pos int, watchedAt string) qaResp {
	e.t.Helper()
	body := map[string]any{"positionSeconds": pos, "durationSeconds": 3000}
	if watchedAt != "" {
		body["watchedAt"] = watchedAt
	}
	return e.do(qaAlice, "POST", "/items/w1/progress", jb(body), "")
}

// seedRow writes w1's owner row directly, for stored states the API can no longer produce.
func (e *progressSeqEnv) seedRow(owner string, pos int, updatedAt string, writeSeq int64) {
	e.t.Helper()
	if _, err := e.db.Exec(`INSERT INTO progress(item_id, user_id, profile_id, position_seconds, duration_seconds, updated_at, write_seq)
		VALUES('w1', ?, ?, ?, 3000, ?, ?)`, qaAlice.id, owner, pos, updatedAt, writeSeq); err != nil {
		e.t.Fatalf("seed progress: %v", err)
	}
}

func (e *progressSeqEnv) wantPos(owner string, want int64, why string) {
	e.t.Helper()
	if pos, _, ok := e.row(owner); !ok || pos != want {
		e.t.Errorf("%s: server holds %d (present=%v), want %d", why, pos, ok, want)
	}
}

// A refused (older) write commits nothing: progress_seq neither advances nor is advertised,
// so no device refetches for a change that did not happen, and the answer is applied:false.
func TestProgressOrder_RefusedWriteMovesNoCounter(t *testing.T) {
	e := newProgressSeqEnv(t)
	owner := e.ownerID(qaAlice)
	wantOK(t, e.postProgressAt(1500, tLate), 200)
	e.assertAdvancedOnce()

	r := e.postProgressAt(600, tEarly)
	wantOK(t, r, 200)
	if r.js["applied"] != false {
		t.Errorf("an older replay answered applied=%v, want false: %s", r.js["applied"], r.raw)
	}
	e.assertAdvancedOnce() // still start+1: the refused write rolled its allocation back
	e.wantPos(owner, 1500, "older replay")
}

// A watch time claimed in the future (device clock set ahead) is stored as the receive time,
// so it cannot outrank a later write that carries no time at all.
func TestProgressOrder_FutureClaimCountsAsReceiveTime(t *testing.T) {
	e := newProgressSeqEnv(t)
	owner := e.ownerID(qaAlice)
	ahead := time.Now().UTC().Add(20 * time.Hour).Format(time.RFC3339)
	wantOK(t, e.postProgressAt(2000, ahead), 200)

	var stored string
	if err := e.reader.QueryRow(`SELECT updated_at FROM progress WHERE item_id='w1' AND profile_id=?`, owner).Scan(&stored); err != nil {
		t.Fatal(err)
	}
	if ts, err := time.Parse(time.RFC3339, stored); err != nil || ts.After(time.Now().UTC().Add(time.Second)) {
		t.Errorf("stored watch time %q is later than the server clock: a fast device clock was trusted", stored)
	}

	r := e.postProgressAt(500, "") // a later write, receive-time stamped
	wantOK(t, r, 200)
	if r.js["applied"] != true {
		t.Errorf("a later receive-time write answered applied=%v, want true: %s", r.js["applied"], r.raw)
	}
	e.wantPos(owner, 500, "later write after a future-dated one")
}

// A stored row dated in the future (written under the old one-day allowance, or before the
// NAS clock was set back) compares as "now": it does not refuse later writes for hours.
func TestProgressOrder_StoredFutureRowDoesNotBlock(t *testing.T) {
	e := newProgressSeqEnv(t)
	owner := e.ownerID(qaAlice)
	e.seedRow(owner, 2000, time.Now().UTC().Add(20*time.Hour).Format(time.RFC3339), 5)

	wantOK(t, e.postProgressAt(700, ""), 200)
	e.wantPos(owner, 700, "write over a future-dated stored row")
}

// An unreadable stored time counts as the oldest possible; it never blocks a write.
func TestProgressOrder_UnreadableStoredTimeDoesNotBlock(t *testing.T) {
	e := newProgressSeqEnv(t)
	owner := e.ownerID(qaAlice)
	e.seedRow(owner, 2000, "not-a-time", 5)

	wantOK(t, e.postProgressAt(700, tEarly), 200)
	e.wantPos(owner, 700, "write over an unreadable stored time")
}

// An unparseable claim falls back to the receive time, which is later than any past watch.
func TestProgressOrder_UnparseableClaimUsesReceiveTime(t *testing.T) {
	e := newProgressSeqEnv(t)
	owner := e.ownerID(qaAlice)
	wantOK(t, e.postProgressAt(1500, tLate), 200)

	wantOK(t, e.postProgressAt(900, "yesterday-ish"), 200)
	e.wantPos(owner, 900, "write with an unparseable watchedAt")
}

// The DS Video WebAPI write is ordered by the same rule: it is receive-time stamped, so it
// beats a past watch, and a stale REST replay afterwards does not undo it.
func TestProgressOrder_WebAPIWriteFollowsTheSameRule(t *testing.T) {
	e := newProgressSeqEnv(t)
	owner := e.ownerID(qaAlice)
	// A minute ago, not tLate: the WebAPI write must win because it is stamped NOW, which a
	// two-week-old reference time could not tell apart from any stale stamp.
	minuteAgo := time.Now().UTC().Add(-time.Minute).Format(time.RFC3339)
	wantOK(t, e.postProgressAt(1500, minuteAgo), 200)

	if r := e.watchStatus(300); !r.Success {
		t.Fatalf("WatchStatus update failed: code %d", r.Error.Code)
	}
	e.wantPos(owner, 300, "WebAPI write after an older REST watch")

	wantOK(t, e.postProgressAt(1500, minuteAgo), 200)
	e.wantPos(owner, 300, "stale REST replay after a WebAPI write")
}

// A NAS whose clock is behind every client degrades to arrival order rather than refusing
// every write: claims and stored times are all capped at the server clock, so they tie and
// write_seq decides.
func TestProgressOrder_ServerClockBehindDegradesToArrivalOrder(t *testing.T) {
	e := newProgressSeqEnv(t)
	owner := e.ownerID(qaAlice)
	e.seedRow(owner, 2000, tLate, 5)

	nasClock := time.Date(2000, 1, 1, 0, 0, 0, 0, time.UTC) // dead RTC after a power cut
	applied, err := e.s.writeProgress(viewer{UserID: qaAlice.id, ProfileID: owner}, "w1", 800, 3000,
		newProgressClock(tEarly, nasClock))
	if err != nil {
		t.Fatalf("writeProgress: %v", err)
	}
	if !applied {
		t.Error("with the NAS clock behind every client, a new write was refused: progress would stop saving until the clock is fixed")
	}
	e.wantPos(owner, 800, "write with the server clock behind")
}

func TestNewProgressClock(t *testing.T) {
	recv := time.Date(2026, 10, 17, 12, 0, 0, 500_000_000, time.UTC)
	for _, c := range []struct{ name, claim, want string }{
		{"absent", "", "2026-10-17T12:00:00Z"},
		{"past claim kept", "2026-10-01T10:00:00Z", "2026-10-01T10:00:00Z"},
		{"offset normalised to UTC", "2026-10-01T12:00:00+02:00", "2026-10-01T10:00:00Z"},
		{"same second kept", "2026-10-17T12:00:00Z", "2026-10-17T12:00:00Z"},
		{"future capped", "2026-10-17T12:00:01Z", "2026-10-17T12:00:00Z"},
		{"unparseable", "garbage", "2026-10-17T12:00:00Z"},
	} {
		got := newProgressClock(c.claim, recv)
		if got.at != c.want {
			t.Errorf("%s: at = %q, want %q", c.name, got.at, c.want)
		}
		if got.now != time.Date(2026, 10, 17, 12, 0, 0, 0, time.UTC).Unix() {
			t.Errorf("%s: now = %d, want the receive second", c.name, got.now)
		}
	}
}
