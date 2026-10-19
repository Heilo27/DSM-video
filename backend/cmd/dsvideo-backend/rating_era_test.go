package main

// FRD-002 FR-241a / FR-244 (TASK-1068, Ryan 2026-10-18): a film rated PG and released in 1984
// or earlier gates at Teens (3). The level is computed on read from content_rating, type and
// year; the one-time recompute re-sequences exactly the titles whose level moved so devices
// that stored age_level from sync fetch the new one.

import (
	"context"
	"reflect"
	"testing"

	"dsvideo/backend/internal/rating"
)

// seedEra inserts a title with an explicit type and year (year 0 means NULL), at change_seq
// seq. It does not touch item_seq.
func (e *qaEnv) seedEra(id, typ string, cert *string, year int, seq int64) {
	e.t.Helper()
	var y any
	if year != 0 {
		y = year
	}
	if _, err := e.db.Exec(`INSERT INTO items(id, library_id, type, title, path, added_at, updated_at, genres, content_rating, year, change_seq)
		VALUES(?, 'lib1', ?, ?, ?, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', '', ?, ?, ?)`,
		id, typ, id, "/media/"+id+".mkv", cert, y, seq); err != nil {
		e.t.Fatalf("seed %s: %v", id, err)
	}
}

// eraEnv is a library a device has fully synced (cursor 8 == item_seq 8) under a server that
// predates FR-241a: the stored ladder record is the live ladder without the era rules.
//
//	jaws84   PG movie 1984  (moves 2 -> 3)
//	raid81   PG movie 1981  (moves 2 -> 3)
//	grease78 PG movie 1978  (moves 2 -> 3)
//	pg85     PG movie 1985  (stays 2)
//	pgnone   PG movie, no year (stays 2: no guess)
//	pg13_84  PG-13 movie 1984 (stays 3)
//	g50      G movie 1950 (stays 1)
//	tvpg     TV-PG episode 1980 (stays 2)
func eraEnv(t *testing.T) *qaEnv {
	t.Helper()
	e := newQAEnv(t)
	e.seedEra("jaws84", "movie", sp("PG"), 1984, 1)
	e.seedEra("raid81", "movie", sp(" pg "), 1981, 2)
	e.seedEra("grease78", "movie", sp("PG"), 1978, 3)
	e.seedEra("pg85", "movie", sp("PG"), 1985, 4)
	e.seedEra("pgnone", "movie", sp("PG"), 0, 5)
	e.seedEra("pg13_84", "movie", sp("PG-13"), 1984, 6)
	e.seedEra("g50", "movie", sp("G"), 1950, 7)
	e.seedEra("tvpg", "episode", sp("TV-PG"), 1980, 8)
	if _, err := e.db.Exec(`UPDATE sync_state SET value=8 WHERE key='item_seq'`); err != nil {
		t.Fatal(err)
	}
	e.recordPreEraLadder()
	return e
}

// recordPreEraLadder stores the ladder record the previous release wrote: the live ladder
// without the era rules.
func (e *qaEnv) recordPreEraLadder() {
	e.t.Helper()
	old := rating.CurrentLevels().WithoutEra()
	if _, err := e.db.Exec(`INSERT INTO rating_ladder_state (id, fingerprint, levels, updated_at) VALUES (1, ?, ?, '2026-01-01T00:00:00Z')`,
		old.Fingerprint(), old.Encode()); err != nil {
		e.t.Fatal(err)
	}
}

// The upgrade recompute bumps exactly the pre-1985 PG movies (one new change_seq, published),
// leaves every other row's change_seq alone, and a second start is a no-op.
// Red if the migration is skipped, bumps unaffected rows, bumps a missing-year PG, or re-runs.
func TestFR241a_UpgradeRecomputeBumpsOnlyAffectedRows(t *testing.T) {
	e := eraEnv(t)
	before := e.changeSeqs()

	res := e.reconcile()
	if !res.Changed || res.Bumped != 3 || res.Seq != 9 {
		t.Fatalf("upgrade reconcile = %+v, want Changed, 3 bumped at seq 9", res)
	}
	want := map[string]int64{
		"jaws84": 9, "raid81": 9, "grease78": 9,
		"pg85": before["pg85"], "pgnone": before["pgnone"], "pg13_84": before["pg13_84"],
		"g50": before["g50"], "tvpg": before["tvpg"],
	}
	if got := e.changeSeqs(); !reflect.DeepEqual(got, want) {
		t.Errorf("change_seq after upgrade = %v, want %v", got, want)
	}
	if got := e.storedItemSeq(); got != 9 {
		t.Errorf("item_seq = %d, want 9", got)
	}
	if published, _ := e.s.getSyncSeqs(); published != 9 {
		t.Errorf("published item_seq = %d, want 9", published)
	}
	if got, wantFP := e.storedLadderFingerprint(), rating.CurrentLevels().Fingerprint(); got != wantFP {
		t.Errorf("stored fingerprint = %s, want live %s", got, wantFP)
	}

	again := e.changeSeqs()
	for i := 0; i < 2; i++ {
		if res := e.reconcile(); res.Baseline || res.Changed || res.Bumped != 0 {
			t.Errorf("start %d after upgrade = %+v, want no-op", i+2, res)
		}
	}
	if got := e.changeSeqs(); !reflect.DeepEqual(got, again) {
		t.Errorf("second run moved change_seq: %v -> %v", again, got)
	}
	if got := e.storedItemSeq(); got != 9 {
		t.Errorf("item_seq after second run = %d, want 9", got)
	}
}

// A database with no ladder record (first ever run of a release that has the ladder table)
// still re-sequences the era titles, because devices hold the ladder-only level. Unaffected
// rows are not touched (FR-244: first run bumps nothing else).
// Red if the baseline run records the live ladder as "already served" and skips the era titles.
func TestFR241a_BaselineRunStillBumpsEraTitles(t *testing.T) {
	e := newQAEnv(t)
	e.seedEra("jaws84", "movie", sp("PG"), 1984, 1)
	e.seedEra("pg85", "movie", sp("PG"), 1985, 2)
	if _, err := e.db.Exec(`UPDATE sync_state SET value=2 WHERE key='item_seq'`); err != nil {
		t.Fatal(err)
	}
	res := e.reconcile()
	if !res.Baseline || res.Bumped != 1 || res.Seq != 3 {
		t.Fatalf("baseline reconcile = %+v, want Baseline, 1 bumped at seq 3", res)
	}
	if got, want := e.changeSeqs(), (map[string]int64{"jaws84": 3, "pg85": 2}); !reflect.DeepEqual(got, want) {
		t.Errorf("change_seq = %v, want %v", got, want)
	}
	if res := e.reconcile(); res.Baseline || res.Changed || res.Bumped != 0 {
		t.Errorf("second run = %+v, want no-op", res)
	}
}

// The stale device case: a client at cursor 8 pulls the delta after the upgrade and receives
// exactly the three era titles, each with ageLevel 3, for an owner and a Teens viewer alike.
// Red if the sync feed computes ageLevel from the certification alone.
func TestFR241a_StaleClientReceivesNewLevelsInDeltaSync(t *testing.T) {
	e := eraEnv(t)
	owner := e.setOwnerPin(qaAlice, "0420")
	teen := e.mustCreate(qaAlice, "0420", "Teen", 3, nil)
	e.s.startupReconcileRatingLadder(context.Background())

	for _, v := range []struct{ name, profile string }{{"owner", owner}, {"teen", teen}} {
		r := e.do(qaAlice, "GET", "/sync/items?since=8&limit=500", "", v.profile)
		if r.code != 200 {
			t.Fatalf("%s: delta = %d %s", v.name, r.code, r.raw)
		}
		items, _ := r.js["items"].([]any)
		seen := map[string]float64{}
		for _, it := range items {
			m := it.(map[string]any)
			seen[m["id"].(string)], _ = m["ageLevel"].(float64)
		}
		if want := map[string]float64{"jaws84": 3, "raid81": 3, "grease78": 3}; !reflect.DeepEqual(seen, want) {
			t.Errorf("%s: delta since 8 = %v, want %v", v.name, seen, want)
		}
	}
}

// Every read path agrees on the level: the full sync feed, the item list and the detail
// answer all say 3 for a 1984 PG film and 2 for a 1985 one or a PG with no year, and the
// server's own gate hides the 1984 film from an Older Kids profile (list and detail) while a
// Teens profile sees it. Red if any one path keeps the ladder-only level.
func TestFR241a_AllReadPathsAgreeAndTheGateUsesTheSameLevel(t *testing.T) {
	e := eraEnv(t)
	owner := e.setOwnerPin(qaAlice, "0420")
	older := e.mustCreate(qaAlice, "0420", "Older", 2, nil)
	teen := e.mustCreate(qaAlice, "0420", "Teen", 3, nil)

	wantLevel := map[string]float64{"jaws84": 3, "raid81": 3, "grease78": 3, "pg85": 2, "pgnone": 2, "pg13_84": 3, "g50": 1, "tvpg": 2}

	sync := e.do(qaAlice, "GET", "/sync/items?since=0&limit=500", "", owner)
	wantOK(t, sync, 200)
	got := map[string]float64{}
	for _, it := range sync.js["items"].([]any) {
		m := it.(map[string]any)
		got[m["id"].(string)], _ = m["ageLevel"].(float64)
	}
	if !reflect.DeepEqual(got, wantLevel) {
		t.Errorf("sync ageLevels = %v, want %v", got, wantLevel)
	}

	for id, lv := range wantLevel {
		d := e.do(qaAlice, "GET", "/items/"+id, "", owner)
		if d.code != 200 {
			t.Errorf("owner detail %s = %d %s", id, d.code, d.raw)
			continue
		}
		if gotLv, _ := d.js["ageLevel"].(float64); gotLv != lv {
			t.Errorf("detail %s ageLevel = %v, want %v", id, gotLv, lv)
		}
	}

	hiddenFromOlder := map[string]bool{"jaws84": true, "raid81": true, "grease78": true, "pg13_84": true}
	for id := range wantLevel {
		od := e.do(qaAlice, "GET", "/items/"+id, "", older)
		if hiddenFromOlder[id] == (od.code == 200) {
			t.Errorf("Older Kids detail %s = %d, hidden want %v", id, od.code, hiddenFromOlder[id])
		}
		td := e.do(qaAlice, "GET", "/items/"+id, "", teen)
		if td.code != 200 {
			t.Errorf("Teens detail %s = %d %s, want 200", id, td.code, td.raw)
		}
	}

	list := func(profile string) map[string]bool {
		r := e.do(qaAlice, "GET", "/items?libraryId=lib1&type=movie&limit=100", "", profile)
		wantOK(t, r, 200)
		out := map[string]bool{}
		for _, id := range r.itemIDs() {
			out[id] = true
		}
		return out
	}
	older2 := list(older)
	for _, id := range []string{"jaws84", "raid81", "grease78"} {
		if older2[id] {
			t.Errorf("Older Kids list shows %s (1984-or-earlier PG)", id)
		}
	}
	for _, id := range []string{"pg85", "pgnone", "g50"} {
		if !older2[id] {
			t.Errorf("Older Kids list hides %s, which stays level 2 or below", id)
		}
	}
	teen2 := list(teen)
	for _, id := range []string{"jaws84", "raid81", "grease78", "pg85", "pgnone", "g50"} {
		if !teen2[id] {
			t.Errorf("Teens list hides %s", id)
		}
	}
}

// TV never carries the era rule: a PG-rated episode (or show row) keeps level 2 whatever
// its year, and ItemLevel is movie-only.
// Red if the rule ignores the item type.
func TestFR241a_EpisodesNeverTakeTheEraRule(t *testing.T) {
	e := newQAEnv(t)
	e.seedEra("ep", "episode", sp("PG"), 1970, 1)
	owner := e.setOwnerPin(qaAlice, "0420")
	r := e.do(qaAlice, "GET", "/sync/items?since=0&limit=10", "", owner)
	wantOK(t, r, 200)
	items, _ := r.js["items"].([]any)
	if len(items) != 1 {
		t.Fatalf("sync items = %s", r.raw)
	}
	if lv, _ := items[0].(map[string]any)["ageLevel"].(float64); lv != 2 {
		t.Errorf("episode ageLevel = %v, want 2", lv)
	}
}
