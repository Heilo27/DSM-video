package main

// FRD-002 FR-244 (TASK-939): a ladder change re-sequences exactly the items whose level
// moved, and only when the ladder actually changed. The variant ladder below is the live
// FR-241 table with PG moved from level 2 to 3 and TV-14 moved from 3 to 2; G, R and
// unrated titles keep their levels.

import (
	"context"
	"reflect"
	"testing"

	"dsvideo/backend/internal/rating"
)

var variantLadder = []rating.Tier{
	{Level: 1, Key: "littleKids", Label: "Little Kids", Movie: []string{"G"}, TV: []string{"TV-Y", "TV-G"}},
	{Level: 2, Key: "olderKids", Label: "Older Kids", Movie: []string{}, TV: []string{"TV-Y7", "TV-Y7-FV", "TV-PG", "TV-14"}},
	{Level: 3, Key: "teens", Label: "Teens", Movie: []string{"PG", "PG-13"}, TV: []string{}},
	{Level: 4, Key: "adult", Label: "Adult", Movie: []string{"R", "NC-17"}, TV: []string{"TV-MA"}},
}

// ladderEnv seeds g (G), pg (PG), tv14 (TV-14), r (R) and unrated (NULL) at change_seq
// 1..5 with item_seq 5, i.e. a library a device has fully synced to cursor 5.
func ladderEnv(t *testing.T) *qaEnv {
	t.Helper()
	e := newQAEnv(t)
	seeds := []struct {
		id   string
		cert *string
	}{{"g", sp("G")}, {"pg", sp("PG")}, {"tv14", sp(" tv-14 ")}, {"r", sp("R")}, {"unrated", nil}}
	for i, s := range seeds {
		e.seedItem(s.id, "", s.cert)
		if _, err := e.db.Exec(`UPDATE items SET change_seq=? WHERE id=?`, i+1, s.id); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := e.db.Exec(`UPDATE sync_state SET value=5 WHERE key='item_seq'`); err != nil {
		t.Fatal(err)
	}
	return e
}

func (e *qaEnv) changeSeqs() map[string]int64 {
	e.t.Helper()
	rows, err := e.db.Query(`SELECT id, change_seq FROM items`)
	if err != nil {
		e.t.Fatal(err)
	}
	defer rows.Close()
	out := map[string]int64{}
	for rows.Next() {
		var id string
		var seq int64
		if err := rows.Scan(&id, &seq); err != nil {
			e.t.Fatal(err)
		}
		out[id] = seq
	}
	return out
}

func (e *qaEnv) storedItemSeq() int64 {
	e.t.Helper()
	var v int64
	if err := e.db.QueryRow(`SELECT value FROM sync_state WHERE key='item_seq'`).Scan(&v); err != nil {
		e.t.Fatal(err)
	}
	return v
}

func (e *qaEnv) storedLadderFingerprint() string {
	e.t.Helper()
	var fp string
	if err := e.db.QueryRow(`SELECT fingerprint FROM rating_ladder_state WHERE id=1`).Scan(&fp); err != nil {
		e.t.Fatal(err)
	}
	return fp
}

func (e *qaEnv) reconcile() ladderReconcileResult {
	e.t.Helper()
	res, err := e.s.reconcileRatingLadder(context.Background())
	if err != nil {
		e.t.Fatalf("reconcileRatingLadder: %v", err)
	}
	return res
}

// First run on a database with no record: the live ladder is recorded and nothing moves.
// A second start with the same ladder is a no-op.
// Red if the first run bumps the library (every device would re-download it) or a
// matching fingerprint bumps anything.
func TestFR244_FirstRunRecordsBaseline_MatchingFingerprintBumpsNothing(t *testing.T) {
	e := ladderEnv(t)
	before := e.changeSeqs()

	if res := e.reconcile(); !res.Baseline || res.Bumped != 0 {
		t.Fatalf("first run = %+v, want a baseline with no bumps", res)
	}
	if got, want := e.storedLadderFingerprint(), rating.CurrentLevels().Fingerprint(); got != want {
		t.Errorf("stored fingerprint = %s, want the live ladder's %s", got, want)
	}

	for i := 0; i < 2; i++ {
		if res := e.reconcile(); res.Baseline || res.Changed || res.Bumped != 0 {
			t.Errorf("restart %d with an unchanged ladder = %+v, want no-op", i+1, res)
		}
	}
	if got := e.changeSeqs(); !reflect.DeepEqual(got, before) {
		t.Errorf("change_seq moved without a ladder change: %v -> %v", before, got)
	}
	if got := e.storedItemSeq(); got != 5 {
		t.Errorf("item_seq = %d, want 5 (nothing allocated)", got)
	}
}

// A changed ladder bumps exactly the items whose level moved, with one new sequence value,
// publishes it, and records the new fingerprint so the next start does nothing.
// Red if unmoved items are re-sent, a moved item is missed, the counter is not published,
// or the fingerprint is not updated (every restart would bump again).
func TestFR244_LadderChangeBumpsOnlyItemsWhoseLevelMoved(t *testing.T) {
	e := ladderEnv(t)
	e.reconcile() // baseline under the live ladder
	before := e.changeSeqs()

	restore := rating.ReplaceLadderForTest(variantLadder)
	defer restore()

	res := e.reconcile()
	if !res.Changed || res.Bumped != 2 || res.Seq != 6 {
		t.Fatalf("reconcile after ladder change = %+v, want Changed, 2 bumped at seq 6", res)
	}
	after := e.changeSeqs()
	want := map[string]int64{"g": before["g"], "pg": 6, "tv14": 6, "r": before["r"], "unrated": before["unrated"]}
	if !reflect.DeepEqual(after, want) {
		t.Errorf("change_seq after ladder change = %v, want %v", after, want)
	}
	if got := e.storedItemSeq(); got != 6 {
		t.Errorf("item_seq = %d, want 6", got)
	}
	if published, _ := e.s.getSyncSeqs(); published != 6 {
		t.Errorf("published item_seq = %d, want 6", published)
	}
	if got, wantFP := e.storedLadderFingerprint(), rating.CurrentLevels().Fingerprint(); got != wantFP {
		t.Errorf("stored fingerprint = %s, want the variant's %s", got, wantFP)
	}

	if res := e.reconcile(); res.Changed || res.Bumped != 0 {
		t.Errorf("second start on the variant ladder = %+v, want no-op", res)
	}
	if got := e.storedItemSeq(); got != 6 {
		t.Errorf("item_seq after second start = %d, want 6", got)
	}
}

// A ladder change that moves no stored title (here: a new certification nobody carries)
// records the new fingerprint without allocating a sequence value.
// Red if an empty change advances item_seq (devices would fetch an empty delta).
func TestFR244_ChangeMovingNoItemUpdatesFingerprintWithoutSeq(t *testing.T) {
	e := ladderEnv(t)
	e.reconcile()
	tiers := rating.Tiers()
	tiers[0].TV = append(tiers[0].TV, "TV-NEW")
	restore := rating.ReplaceLadderForTest(tiers)
	defer restore()

	if res := e.reconcile(); !res.Changed || res.Bumped != 0 || res.Seq != 0 {
		t.Fatalf("reconcile = %+v, want Changed with nothing bumped", res)
	}
	if got := e.storedItemSeq(); got != 5 {
		t.Errorf("item_seq = %d, want 5", got)
	}
	if got, want := e.storedLadderFingerprint(), rating.CurrentLevels().Fingerprint(); got != want {
		t.Errorf("fingerprint not updated: %s, want %s", got, want)
	}
}

// A stored mapping that cannot be read means the moved items are unknown: every item is
// re-sent once.
// Red if a corrupt record is treated as "nothing moved".
func TestFR244_UnreadableStoredLadderResendsEveryItem(t *testing.T) {
	e := ladderEnv(t)
	if _, err := e.db.Exec(`INSERT INTO rating_ladder_state (id, fingerprint, levels, updated_at)
		VALUES (1, 'stale', 'not json', '2026-01-01T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	if res := e.reconcile(); !res.Changed || res.Bumped != 5 || res.Seq != 6 {
		t.Fatalf("reconcile = %+v, want all 5 items bumped at seq 6", res)
	}
	for id, seq := range e.changeSeqs() {
		if seq != 6 {
			t.Errorf("%s change_seq = %d, want 6", id, seq)
		}
	}
}

// OC-2135, ladder variant. Given a device cursor C after a full sync, when a ladder change
// that moves some certifications is deployed (the server restarts on the new ladder), then
// GET /sync/items?since=C returns every item whose ageLevel changed, with its new
// ageLevel, for an unrestricted and a level-1 viewer alike, and nothing else.
// Red if the startup reconcile does not run its bump, or ageLevel is served from the old
// ladder.
func TestOC2135_LadderChangeReachesDeltaSyncWithNewAgeLevel(t *testing.T) {
	e := ladderEnv(t)
	owner := e.setOwnerPin(qaAlice, "0420")
	kid := e.mustCreate(qaAlice, "0420", "Kid", 1, nil)
	e.reconcile() // the release before: baseline

	full := e.do(qaAlice, "GET", "/sync/items?since=0&limit=500", "", owner)
	if full.code != 200 || full.num("nextSeq") != 5 || len(idsOf(t, full, "items")) != 5 {
		t.Fatalf("precondition: full sync = %s, want 5 items and nextSeq 5", full.raw)
	}

	restore := rating.ReplaceLadderForTest(variantLadder)
	defer restore()
	e.s.startupReconcileRatingLadder(context.Background()) // the new release starts

	want := map[string]float64{"pg": 3, "tv14": 2}
	for _, v := range []struct{ name, profile string }{{"owner", owner}, {"kid", kid}} {
		r := e.do(qaAlice, "GET", "/sync/items?since=5&limit=500", "", v.profile)
		if r.code != 200 {
			t.Fatalf("%s: delta sync = %d %s", v.name, r.code, r.raw)
		}
		items, _ := r.js["items"].([]any)
		seen := map[string]float64{}
		for _, it := range items {
			m := it.(map[string]any)
			seen[m["id"].(string)], _ = m["ageLevel"].(float64)
		}
		if !reflect.DeepEqual(seen, want) {
			t.Errorf("%s: delta since C = %v, want exactly %v", v.name, seen, want)
		}
		if r.num("nextSeq") != 6 {
			t.Errorf("%s: nextSeq = %d, want 6", v.name, r.num("nextSeq"))
		}
	}
}
