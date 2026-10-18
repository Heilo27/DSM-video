package main

// Oracle OC-1027 / OC-1033 / OC-1023 (FRD-001 FR-013, FR-014, FR-019, FR-023), driven through
// the real router and handleProgress. Expected values are literals; the watch times are the
// clock the CLIENT stamps on each write (progressRequest.WatchedAt), because that is what
// "older" and "newer" mean to a user: when the title was watched, not when the NAS heard of it.
//
// The scenario every test here shares: device X watched earlier but synced later (offline
// outbox replay); device Y watched later and synced first. Both are the same profile.

import (
	"testing"
)

const (
	tEarly = "2026-10-01T10:00:00Z" // when X watched
	tLate  = "2026-10-01T11:00:00Z" // when Y watched, an hour after X
)

type progWrite struct {
	pos, dur  int
	watchedAt string
}

// postProgress sends one progress write as device `device` (a label for failure messages only;
// the server cannot tell devices apart, which is the point: same account, same profile).
func postProgress(t *testing.T, e *qaEnv, profile, item string, w progWrite) {
	t.Helper()
	wantOK(t, e.do(qaAlice, "POST", "/items/"+item+"/progress", jb(map[string]any{
		"positionSeconds": w.pos, "durationSeconds": w.dur, "watchedAt": w.watchedAt,
	}), profile), 200)
}

// storedPosition reads what any device would be handed by GET /progress/all for the item;
// ok=false when the item has no row.
func storedPosition(t *testing.T, e *qaEnv, profile, item string) (pos int, ok bool) {
	t.Helper()
	r := e.do(qaAlice, "GET", "/progress/all", "", profile)
	prog, _ := r.js["progress"].(map[string]any)
	row, found := prog[item].(map[string]any)
	if !found {
		return 0, false
	}
	return int(row["positionSeconds"].(float64)), true
}

// OC-1027 / FR-014. Y records 1500s (watched at tLate) and syncs; X then syncs its older 600s
// (watched at tEarly). Both devices must be handed 1500s. Red if handleProgress orders writes by
// arrival (write_seq alone) instead of by when the title was watched: the late-arriving older
// write then lands with the higher write_seq and replaces 1500 with 600.
func TestOC1027_AnOlderWatchSyncedLaterNeverOverwritesANewerPosition(t *testing.T) {
	e := newQAEnv(t)
	owner := e.setOwnerPin(qaAlice, "0420")
	e.seedItem("t1", "Drama", sp("PG"))

	postProgress(t, e, owner, "t1", progWrite{1500, 3000, tLate}) // Y, syncs first
	postProgress(t, e, owner, "t1", progWrite{600, 3000, tEarly}) // X, older, syncs afterwards

	pos, ok := storedPosition(t, e, owner, "t1")
	if !ok || pos != 1500 {
		t.Errorf("[Contract Unmet FR-014] after X replayed its older 600s, the server hands every device position %d (present=%v); want 1500: an older watch overwrote a newer one", pos, ok)
	}
}

// OC-1027 control: the same two writes in watch order (older first, newer second) keep the newer
// one. Pins that the fix for the replay case cannot be "never accept a lower number": 1500 then
// 600-watched-later is a legitimate rewind (FR-023), and must land.
func TestOC1027_ANewerWatchStillReplacesAnOlderOneEvenWhenItIsALowerPosition(t *testing.T) {
	e := newQAEnv(t)
	owner := e.setOwnerPin(qaAlice, "0420")
	e.seedItem("t1", "Drama", sp("PG"))

	postProgress(t, e, owner, "t1", progWrite{1500, 3000, tEarly})
	postProgress(t, e, owner, "t1", progWrite{300, 3000, tLate}) // deliberate rewind, later in time

	if pos, ok := storedPosition(t, e, owner, "t1"); !ok || pos != 300 {
		t.Errorf("a later, lower position (rewind, FR-023) was refused: server holds %d (present=%v), want 300", pos, ok)
	}
}

// OC-1027 boundary: two writes stamped in the same second keep arrival order, so an explicit
// "mark unwatched" (position 0) right after 4000 is honoured. Red if a fix compares watch times
// with >= and lets a tie keep the old row.
func TestOC1027_TwoWritesInTheSameSecondFollowArrivalOrder(t *testing.T) {
	e := newQAEnv(t)
	owner := e.setOwnerPin(qaAlice, "0420")
	e.seedItem("t1", "Drama", sp("PG"))

	postProgress(t, e, owner, "t1", progWrite{4000, 6000, tLate})
	postProgress(t, e, owner, "t1", progWrite{0, 6000, tLate})

	if pos, ok := storedPosition(t, e, owner, "t1"); !ok || pos != 0 {
		t.Errorf("a same-second write of 0 after 4000 did not land: server holds %d (present=%v), want 0", pos, ok)
	}
}

// OC-1033 / FR-019 (destructive). X marks T watched (position = duration = 1800, watched at
// tLate) and syncs. Y then replays stale 40% progress (720s, watched at tEarly). The server must
// keep the cleared (finished) state: 1800 of 1800, so T cannot re-enter Continue Watching.
// Red if the stale replay is accepted and T comes back at 720.
func TestOC1033_AStaleReplayNeverResurrectsAMarkedWatchedTitle(t *testing.T) {
	e := newQAEnv(t)
	owner := e.setOwnerPin(qaAlice, "0420")
	e.seedItem("t1", "Drama", sp("PG"))
	e.seedItem("other", "Drama", sp("PG"))
	postProgress(t, e, owner, "other", progWrite{900, 1800, tEarly}) // survivor: must be untouched

	postProgress(t, e, owner, "t1", progWrite{1800, 1800, tLate}) // X: Mark as Watched
	postProgress(t, e, owner, "t1", progWrite{720, 1800, tEarly}) // Y: stale 40%, syncs afterwards

	if pos, ok := storedPosition(t, e, owner, "t1"); !ok || pos != 1800 {
		t.Errorf("[Contract Unmet FR-019] a stale replay resurrected a watched title: server holds %d (present=%v), want 1800 (finished)", pos, ok)
	}
	if pos, ok := storedPosition(t, e, owner, "other"); !ok || pos != 900 {
		t.Errorf("an unrelated title's position changed: %d (present=%v), want 900", pos, ok)
	}
}

// OC-1033 control: Mark as Unwatched (position 0 watched later) on top of an older 40% clears it,
// and an older replay of that 40% after the clear does not bring it back.
func TestOC1033_AStaleReplayNeverResurrectsAClearedResumePoint(t *testing.T) {
	e := newQAEnv(t)
	owner := e.setOwnerPin(qaAlice, "0420")
	e.seedItem("t1", "Drama", sp("PG"))

	postProgress(t, e, owner, "t1", progWrite{720, 1800, tEarly})
	postProgress(t, e, owner, "t1", progWrite{0, 1800, tLate})   // X: cleared
	postProgress(t, e, owner, "t1", progWrite{720, 1800, tEarly}) // Y: replays the same stale 40%

	if pos, ok := storedPosition(t, e, owner, "t1"); !ok || pos != 0 {
		t.Errorf("[Contract Unmet FR-019] a cleared resume point came back: server holds %d (present=%v), want 0", pos, ok)
	}
}
