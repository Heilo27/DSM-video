package main

// FRD-002 destructive-path oracle assertions with no (or weak) coverage before TASK-938:
// OC-2011 (FR-201), OC-2100 (FR-231), OC-2135 (FR-244). Driven through the real router and
// handlers; every expected value is a literal. Each test names the change that turns it red.

import (
	"context"
	"net/http"
	"reflect"
	"sort"
	"testing"

	"dsvideo/backend/internal/metadata"
)

func watchlistIDs(t *testing.T, e *qaEnv, profile string) []string {
	t.Helper()
	r := e.do(qaAlice, "GET", "/watchlist", "", profile)
	if r.code != http.StatusOK {
		t.Fatalf("GET /watchlist = %d %s", r.code, r.raw)
	}
	var out []string
	for id := range idsOf(t, r, "items") {
		out = append(out, id)
	}
	sort.Strings(out)
	return out
}

func watchlistRows(e *qaEnv, profile string) int {
	return e.count(`SELECT COUNT(*) FROM watchlist WHERE profile_id = ?`, profile)
}

// OC-2011 / FR-201. Given A and B both hold T, when B deletes T, then B's watchlist is one
// shorter with T absent, and A's still holds T with its count unchanged. A second DELETE by
// B is an idempotent no-op that still leaves A alone (boundary).
// Red if handleWatchlistRemove's DELETE drops `AND profile_id = ?` (or keys by user_id):
// A's T row would go too.
func TestOC2011_DeleteUnderBRemovesOnlyBsCopyWhenBothHoldIt(t *testing.T) {
	e := newQAEnv(t)
	a := e.setOwnerPin(qaAlice, "0420")
	b := e.mustCreate(qaAlice, "0420", "Bee", 4, nil)
	for _, id := range []string{"t", "u", "v"} {
		e.seedItem(id, "", sp("PG"))
	}
	for _, add := range []struct{ item, profile string }{{"t", a}, {"u", a}, {"t", b}, {"v", b}} {
		wantOK(t, e.do(qaAlice, "POST", "/watchlist/"+add.item, "", add.profile), 200)
	}
	if na, nb := watchlistRows(e, a), watchlistRows(e, b); na != 2 || nb != 2 {
		t.Fatalf("precondition: A has %d rows, B has %d, want 2 and 2", na, nb)
	}

	r := e.do(qaAlice, "DELETE", "/watchlist/t", "", b)
	wantOK(t, r, 200)
	if r.js["removed"] != true {
		t.Errorf("B's DELETE of a T it holds reported removed=%v, want true", r.js["removed"])
	}

	if n := watchlistRows(e, b); n != 1 {
		t.Errorf("B has %d watchlist rows after the delete, want 1 (2 - 1)", n)
	}
	if got := watchlistIDs(t, e, b); !reflect.DeepEqual(got, []string{"v"}) {
		t.Errorf("B's watchlist = %v, want [v]", got)
	}
	if r := e.do(qaAlice, "GET", "/watchlist/t", "", b); r.js["inWatchlist"] != false {
		t.Errorf("GET /watchlist/t under B = %s, want inWatchlist false", r.raw)
	}
	if n := watchlistRows(e, a); n != 2 {
		t.Errorf("A has %d watchlist rows after B's delete, want 2 (unchanged)", n)
	}
	if got := watchlistIDs(t, e, a); !reflect.DeepEqual(got, []string{"t", "u"}) {
		t.Errorf("A's watchlist = %v, want [t u]", got)
	}
	if r := e.do(qaAlice, "GET", "/watchlist/t", "", a); r.js["inWatchlist"] != true {
		t.Errorf("GET /watchlist/t under A = %s, want inWatchlist true", r.raw)
	}

	// Repeat: idempotent, removes nothing, A still intact.
	r = e.do(qaAlice, "DELETE", "/watchlist/t", "", b)
	wantOK(t, r, 200)
	if r.js["removed"] != false {
		t.Errorf("second DELETE reported removed=%v, want false", r.js["removed"])
	}
	if n := e.count(`SELECT COUNT(*) FROM watchlist WHERE item_id='t' AND profile_id=?`, a); n != 1 {
		t.Errorf("A's T row count = %d after B's repeated delete, want 1", n)
	}
}

// OC-2100 / FR-231. Given K saved T (PG-13, level 3) while K was level 3, and K was then
// lowered to level 1, when K deletes T, then the delete is allowed (200, removed) and after
// raising K back to 3, T is not in K's watchlist. K's other entry and another profile's copy
// of T survive (target + survivor identity).
// Red if the ceiling check that guards adds (refuseAboveCeiling) is applied to removals, or
// the removal silently matches nothing for a hidden item: T would reappear at level 3.
func TestOC2100_WatchlistDeleteAboveCeilingIsAllowedAndSticks(t *testing.T) {
	e := newQAEnv(t)
	e.setOwnerPin(qaAlice, "0420")
	k := e.mustCreate(qaAlice, "0420", "Kay", 3, nil)
	other := e.mustCreate(qaAlice, "0420", "Other", 4, nil)
	e.seedItem("t", "", sp("PG-13"))
	e.seedItem("g1", "", sp("G"))
	wantOK(t, e.do(qaAlice, "POST", "/watchlist/t", "", k), 200)
	wantOK(t, e.do(qaAlice, "POST", "/watchlist/g1", "", k), 200)
	wantOK(t, e.do(qaAlice, "POST", "/watchlist/t", "", other), 200)

	wantOK(t, e.do(qaAlice, "PATCH", "/profiles/"+k, jb(map[string]any{"ownerPin": "0420", "maxAgeLevel": 1}), ""), 200)
	// Precondition: the ceiling is really in force for K now (T is above it).
	if r := e.do(qaAlice, "POST", "/watchlist/t", "", k); r.code == http.StatusOK {
		t.Fatalf("precondition: K at level 1 could add PG-13 T (%s); ceiling not in force", r.raw)
	}
	if n := watchlistRows(e, k); n != 2 {
		t.Fatalf("precondition: K has %d watchlist rows, want 2 (t, g1)", n)
	}

	r := e.do(qaAlice, "DELETE", "/watchlist/t", "", k)
	wantOK(t, r, 200)
	if r.js["removed"] != true {
		t.Errorf("DELETE above ceiling reported removed=%v, want true", r.js["removed"])
	}
	if n := watchlistRows(e, k); n != 1 {
		t.Errorf("K has %d rows after deleting T, want 1", n)
	}
	if n := e.count(`SELECT COUNT(*) FROM watchlist WHERE profile_id=? AND item_id='g1'`, k); n != 1 {
		t.Errorf("K's surviving g1 row count = %d, want 1", n)
	}
	if n := e.count(`SELECT COUNT(*) FROM watchlist WHERE profile_id=? AND item_id='t'`, other); n != 1 {
		t.Errorf("Other's T row count = %d after K's delete, want 1", n)
	}

	wantOK(t, e.do(qaAlice, "PATCH", "/profiles/"+k, jb(map[string]any{"ownerPin": "0420", "maxAgeLevel": 3}), ""), 200)
	if got := watchlistIDs(t, e, k); !reflect.DeepEqual(got, []string{"g1"}) {
		t.Errorf("K's watchlist after raising to 3 = %v, want [g1] (T must stay deleted)", got)
	}
}

// OC-2135 / FR-244 (rating half). Given a device cursor C taken after a full sync, when an
// item's certification changes server-side (the content-rating backfill writes a new rating),
// then GET /sync/items?since=C returns exactly the changed items, each with its NEW
// contentRating and ageLevel, for an unrestricted and a level-1 viewer alike; an unchanged item
// is not re-sent.
// Red if recordExtras stops bumping change_seq (the delta would be empty and devices keep the
// old level), or ageLevel is computed from a stale value.
// NOT covered: a ladder edit itself. The ladder is a compile-time table (internal/rating) and
// ageLevel is derived at read time; no migration bumps change_seq when the ladder moves (see
// the TASK-938 report). The golden TestAC00210_TiersMatchTheAPIDocTableExactly is the only
// tripwire for that.
func TestOC2135_CertificationChangeReachesDeltaSyncWithNewAgeLevel(t *testing.T) {
	e := newQAEnv(t)
	owner := e.setOwnerPin(qaAlice, "0420")
	kid := e.mustCreate(qaAlice, "0420", "Kid", 1, nil)
	e.seedItem("x1", "", nil)         // unrated -> 4
	e.seedItem("x2", "", sp("PG-13")) // 3
	e.seedItem("keep", "", sp("R"))   // 4, never changes
	for i, id := range []string{"x1", "x2", "keep"} {
		if _, err := e.db.Exec(`UPDATE items SET change_seq=?, tmdb_extras_checked_at=NULL WHERE id=?`, i+1, id); err != nil {
			t.Fatal(err)
		}
	}
	res, err := e.db.Exec(`UPDATE sync_state SET value=3 WHERE key='item_seq'`)
	if err != nil {
		t.Fatal(err)
	}
	if n, _ := res.RowsAffected(); n != 1 {
		t.Fatalf("precondition: sync_state item_seq row missing (%d rows)", n)
	}

	full := e.do(qaAlice, "GET", "/sync/items?since=0&limit=500", "", owner)
	if full.code != 200 || full.num("nextSeq") != 3 || len(idsOf(t, full, "items")) != 3 {
		t.Fatalf("precondition: full sync = %s, want 3 items and nextSeq 3", full.raw)
	}

	ctx := context.Background()
	if err := e.s.recordExtras(ctx, []string{"x1"}, metadata.Extras{ContentRating: "G"}); err != nil {
		t.Fatal(err)
	}
	if err := e.s.recordExtras(ctx, []string{"x2"}, metadata.Extras{ContentRating: "TV-MA"}); err != nil {
		t.Fatal(err)
	}

	type got struct {
		cert  string
		level float64
	}
	want := map[string]got{"x1": {"G", 1}, "x2": {"TV-MA", 4}}
	for _, v := range []struct{ name, profile string }{{"owner", owner}, {"kid", kid}} {
		r := e.do(qaAlice, "GET", "/sync/items?since=3&limit=500", "", v.profile)
		if r.code != 200 {
			t.Fatalf("%s: delta sync = %d %s", v.name, r.code, r.raw)
		}
		items, _ := r.js["items"].([]any)
		seen := map[string]got{}
		for _, it := range items {
			m := it.(map[string]any)
			c, _ := m["contentRating"].(string)
			l, _ := m["ageLevel"].(float64)
			seen[m["id"].(string)] = got{c, l}
		}
		if !reflect.DeepEqual(seen, want) {
			t.Errorf("%s: delta since C = %v, want exactly %v (keep must not be re-sent)", v.name, seen, want)
		}
		if r.num("nextSeq") != 5 {
			t.Errorf("%s: nextSeq = %d, want 5", v.name, r.num("nextSeq"))
		}
	}
}
