package main

// TASK-985 — GET /api/v1/libraries lists the configured libraries (FR-080, FR-099).

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"
)

type listedLib struct {
	ID    string
	Title string
	Kind  string
	Path  any
}

// getLibraries reads the real route. lastScanAt is fresh so the handler's stale-scan
// background trigger does not walk the (fake) paths during the test.
func getLibraries(t *testing.T, movies, tv, home string) ([]listedLib, qaResp) {
	t.Helper()
	e := newQAEnv(t)
	e.s.cfg.MoviesPath, e.s.cfg.TVPath, e.s.cfg.HomePath = movies, tv, home
	e.s.lastScanAt = time.Now()
	r := e.do(qaAlice, http.MethodGet, "/libraries", "", "")
	wantOK(t, r, http.StatusOK)
	var body struct {
		Libraries []map[string]any `json:"libraries"`
	}
	if err := json.Unmarshal(r.raw, &body); err != nil {
		t.Fatalf("decode %s: %v", r.raw, err)
	}
	if body.Libraries == nil {
		t.Fatalf("libraries decoded as null, want a list: %s", r.raw)
	}
	var out []listedLib
	for _, m := range body.Libraries {
		out = append(out, listedLib{
			ID: m["id"].(string), Title: m["title"].(string), Kind: m["kind"].(string), Path: m["path"],
		})
	}
	return out, r
}

func TestLibraries_HomeVideosIsListedWhenConfigured(t *testing.T) {
	libs, r := getLibraries(t, "/vol/movies", "/vol/tv", "/vol/home")
	if len(libs) != 3 {
		t.Fatalf("want movies, tv and home; got %s", r.raw)
	}
	want := []listedLib{
		{ID: "lib_movies", Title: "Movies", Kind: "movies"},
		{ID: "lib_tv", Title: "TV Shows", Kind: "tv"},
		{ID: "lib_home", Title: "Home Videos", Kind: "home"},
	}
	for i, w := range want {
		g := libs[i]
		if g.ID != w.ID || g.Title != w.Title || g.Kind != w.Kind {
			t.Errorf("library %d = %+v, want %+v", i, g, w)
		}
	}
}

func TestLibraries_OnlyConfiguredLibrariesAreListed(t *testing.T) {
	libs, r := getLibraries(t, "/vol/movies", "", "")
	if len(libs) != 1 || libs[0].ID != "lib_movies" {
		t.Fatalf("Movies-only server must list Movies only; got %s", r.raw)
	}
	libs, r = getLibraries(t, "", "", "")
	if len(libs) != 0 {
		t.Fatalf("unconfigured server must list nothing; got %s", r.raw)
	}
}

func TestLibraries_NeverLeaksFilesystemPaths(t *testing.T) {
	libs, r := getLibraries(t, "/vol/movies", "/vol/tv", "/vol/home")
	for _, l := range libs {
		if l.Path != nil {
			t.Errorf("%s exposes path %v to a non-admin (TASK-811): %s", l.ID, l.Path, r.raw)
		}
	}
}

// A listed library must open: the by-folder view resolves its root from the same config.
func TestLibraries_HomeVideosOpensByFolder(t *testing.T) {
	e := newQAEnv(t)
	e.s.cfg.HomePath = "/vol/home"
	if _, err := e.db.Exec(`INSERT INTO items(id, library_id, type, title, path, added_at, updated_at)
		VALUES('hv1','lib_home','homeVideo','Beach 2019','/vol/home/Trips/Beach.mp4','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	r := e.do(qaAlice, http.MethodGet, "/items?libraryId=lib_home&filter=byFolder", "", "")
	wantOK(t, r, http.StatusOK)
	r = e.do(qaAlice, http.MethodGet, "/items?libraryId=lib_home", "", "")
	wantOK(t, r, http.StatusOK)
	if r.num("total") != 1 {
		t.Errorf("home library lists %d items, want 1: %s", r.num("total"), r.raw)
	}
	r = e.do(qaAlice, http.MethodGet, "/items?libraryId=lib_nope&filter=byFolder", "", "")
	wantErr(t, r, http.StatusBadRequest, "invalid_library")
}

// FR-086/FR-099: a home video with no year, rating, cast, genres or overview opens, and the
// payload carries nulls the client omits, never placeholder text.
func TestLibraries_BareHomeVideoDetailHasNoPlaceholders(t *testing.T) {
	e := newQAEnv(t)
	if _, err := e.db.Exec(`INSERT INTO items(id, library_id, type, title, path, added_at, updated_at)
		VALUES('hv1','lib_home','homeVideo','Beach 2019','/vol/home/Beach.mp4','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	r := e.do(qaAlice, http.MethodGet, "/items/hv1", "", "")
	wantOK(t, r, http.StatusOK)
	for _, k := range []string{"year", "rating", "summary", "director", "originalTitle", "contentRating"} {
		if v, present := r.js[k]; !present || v != nil {
			t.Errorf("%s = %#v, want present and null (no placeholder text)", k, v)
		}
	}
	for _, k := range []string{"genres", "cast"} {
		if v := r.js[k]; v != nil {
			if l, ok := v.([]any); !ok || len(l) != 0 {
				t.Errorf("%s = %#v, want null or empty", k, v)
			}
		}
	}
	if r.str("title") != "Beach 2019" {
		t.Errorf("title = %q", r.str("title"))
	}
}
