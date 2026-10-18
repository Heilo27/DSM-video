package main

// TASK-747 / FR-151: GET /items/{id}/similar. Every test observes the HTTP answer a client gets.

import (
	"fmt"
	"reflect"
	"testing"
)

func (e *colEnv) setYear(id string, year int) {
	e.t.Helper()
	if _, err := e.db.Exec(`UPDATE items SET year = ? WHERE id = ?`, year, id); err != nil {
		e.t.Fatalf("set year %s: %v", id, err)
	}
}

func (e *colEnv) similar(profile, id, query string) qaResp {
	e.t.Helper()
	return e.do(qaAlice, "GET", "/items/"+id+"/similar"+query, "", profile)
}

func (e *colEnv) similarIDs(profile, id, query string) []string {
	e.t.Helper()
	r := e.similar(profile, id, query)
	wantOK(e.t, r, 200)
	return r.itemIDs()
}

func TestFR151_SharedGenreAndCollectionRankHigher(t *testing.T) {
	e := newColEnv(t)
	e.movie("seed", "Sci-Fi,Adventure", nil, 1)
	e.movie("two_genres", "Sci-Fi,Adventure", nil, 2)
	e.movie("one_genre", "Sci-Fi,Western", nil, 3)
	e.movie("no_overlap", "Romance", nil, 4)
	e.movie("same_collection", "Romance", nil, 5) // no shared genre, but the seed's studio
	e.tagCompany("seed", tagKindCompany, 3)       // Pixar
	e.tagCompany("same_collection", tagKindCompany, 3)

	got := e.similarIDs(e.owner, "seed", "")
	want := []string{"two_genres", "same_collection", "one_genre"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("order = %v, want %v (two shared genres > shared collection > one shared genre; no overlap absent; seed absent)", got, want)
	}
}

func TestFR151_DecadeAndKindBreakTies(t *testing.T) {
	e := newColEnv(t)
	e.movie("seed", "Mystery", nil, 1)
	e.movie("same_decade", "Mystery", nil, 2)
	e.movie("far_decade", "Mystery", nil, 3)
	e.episode("a_show_ep", "Zed Show", "Mystery", nil, 4)
	e.setYear("seed", 1994)
	e.setYear("same_decade", 1991)
	e.setYear("far_decade", 2020)
	e.setYear("a_show_ep", 2021)

	got := e.similarIDs(e.owner, "seed", "")
	want := []string{"same_decade", "far_decade", "a_show_ep"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("order = %v, want %v (same decade, then far decade, then a show for a movie seed)", got, want)
	}
}

func TestFR151_RestrictedProfileNeverSeesOverCeilingTitles(t *testing.T) {
	e := newColEnv(t)
	e.movie("g_seed", "Animation,Family", sp("G"), 1)
	e.movie("g_peer", "Animation,Family", sp("G"), 2)
	e.movie("r_peer", "Animation,Family", sp("R"), 3)
	e.movie("unrated_peer", "Animation,Family", nil, 4)
	e.movie("r_seed", "Animation,Family", sp("R"), 5)

	for _, id := range e.similarIDs(e.kid, "g_seed", "") {
		if id == "r_peer" || id == "unrated_peer" {
			t.Fatalf("kid was shown %s, above the profile's ceiling", id)
		}
	}
	if got := e.similarIDs(e.kid, "g_seed", ""); !reflect.DeepEqual(got, []string{"g_peer"}) {
		t.Fatalf("kid got %v, want [g_peer]", got)
	}
	// The unrestricted profile still sees them.
	if got := e.similarIDs(e.owner, "g_seed", ""); len(got) != 4 {
		t.Fatalf("owner got %v, want all 4 peers", got)
	}

	// An over-ceiling seed is refused with the status GET /items/{id} gives.
	detail := e.do(qaAlice, "GET", "/items/r_seed", "", e.kid)
	r := e.similar(e.kid, "r_seed", "")
	if r.code != 403 || r.code != detail.code || r.str("error") != detail.str("error") {
		t.Fatalf("similar for restricted seed = %d %s, item detail = %d %s", r.code, r.raw, detail.code, detail.raw)
	}
	wantOK(t, e.similar(e.owner, "r_seed", ""), 200)
}

func TestFR151_EpisodesCollapseToOneEntryPerShow(t *testing.T) {
	e := newColEnv(t)
	e.movie("seed", "Crime", nil, 1)
	for i := 1; i <= 4; i++ {
		e.episode(fmt.Sprintf("alpha_%d", i), "Alpha", "Crime", nil, 10+i)
	}
	e.episode("beta_1", "Beta", "Crime", nil, 20)
	e.episode("beta_2", "Beta", "Crime", nil, 21)

	r := e.similar(e.owner, "seed", "")
	wantOK(t, r, 200)
	items, _ := r.js["items"].([]any)
	if len(items) != 2 {
		t.Fatalf("got %d entries %s, want 2 (one per show)", len(items), r.raw)
	}
	titles := map[string]bool{}
	for _, it := range items {
		m := it.(map[string]any)
		titles[m["title"].(string)] = true
		if m["showName"] != m["title"] {
			t.Errorf("show entry title %v / showName %v should both be the show", m["title"], m["showName"])
		}
	}
	if !titles["Alpha"] || !titles["Beta"] {
		t.Fatalf("titles = %v, want Alpha and Beta", titles)
	}

	// Seeded from an episode, its own show never comes back; the other show does, once, and
	// the Crime movie is a legitimate match alongside it.
	got := e.similarIDs(e.owner, "alpha_2", "")
	betaEntries, others := 0, []string{}
	for _, id := range got {
		switch id {
		case "beta_1", "beta_2":
			betaEntries++
		default:
			others = append(others, id)
		}
	}
	if betaEntries != 1 || !reflect.DeepEqual(others, []string{"seed"}) || len(got) != 2 {
		t.Fatalf("from an Alpha episode got %v, want Beta once plus the Crime movie, and no Alpha episode", got)
	}
}

func TestFR151_LimitIsClamped(t *testing.T) {
	e := newColEnv(t)
	e.movie("seed", "Horror", nil, 1)
	for i := 0; i < 40; i++ {
		e.movie(fmt.Sprintf("peer_%02d", i), "Horror", nil, 2)
	}
	for _, tc := range []struct {
		query string
		want  int
	}{
		{"", 12},
		{"?limit=5", 5},
		{"?limit=100", 30},
		{"?limit=30", 30},
		{"?limit=0", 1},
		{"?limit=-7", 1},
		{"?limit=abc", 12},
	} {
		if got := len(e.similarIDs(e.owner, "seed", tc.query)); got != tc.want {
			t.Errorf("%q returned %d items, want %d", tc.query, got, tc.want)
		}
	}
}

func TestFR151_UnknownIDIs404(t *testing.T) {
	e := newColEnv(t)
	r := e.similar(e.owner, "no_such_item", "")
	if r.code != 404 || r.str("error") != "not_found" {
		t.Fatalf("got %d %s, want 404 not_found", r.code, r.raw)
	}
}

func TestFR151_SeedWithNothingToMatchOnIsAnEmptyList(t *testing.T) {
	e := newColEnv(t)
	e.movie("bare", "", nil, 1)
	e.movie("other", "Drama", nil, 2)
	r := e.similar(e.owner, "bare", "")
	wantOK(t, r, 200)
	items, ok := r.js["items"].([]any)
	if !ok || len(items) != 0 {
		t.Fatalf("got %s, want {\"items\":[]}", r.raw)
	}
}

// The entries are the /items list element, built by the same itemSummary: for a movie the
// two answers are identical field for field.
func TestFR151_EntriesAreTheStandardItemSummary(t *testing.T) {
	e := newColEnv(t)
	e.movie("seed", "Drama", sp("PG"), 1)
	e.movie("peer", "Drama", sp("PG"), 2)
	if _, err := e.db.Exec(`UPDATE items SET year = 2001, rating = 7.5, duration_seconds = 5400, poster_path = '/p' WHERE id = 'peer'`); err != nil {
		t.Fatal(err)
	}

	list := e.do(qaAlice, "GET", "/items?libraryId=lib_movies", "", e.owner)
	wantOK(t, list, 200)
	var fromList map[string]any
	for _, it := range list.js["items"].([]any) {
		if m := it.(map[string]any); m["id"] == "peer" {
			fromList = m
		}
	}
	r := e.similar(e.owner, "seed", "")
	wantOK(t, r, 200)
	items := r.js["items"].([]any)
	if len(items) != 1 || fromList == nil {
		t.Fatalf("similar = %s", r.raw)
	}
	if !reflect.DeepEqual(items[0], any(fromList)) {
		t.Fatalf("similar entry %v differs from /items entry %v", items[0], fromList)
	}
}
