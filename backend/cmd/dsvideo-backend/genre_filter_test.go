package main

import (
	"database/sql"
	"strings"
	"testing"

	_ "modernc.org/sqlite"
)

// Genres are stored comma-joined ("Action,Comedy"), so filtering is a LIKE against a
// comma-wrapped copy. The wrapping is what makes the match EXACT, and that is the whole
// risk in this feature: a naive LIKE '%Drama%' also matches "Docudrama", and '%Action%'
// matches "Action & Adventure". Both would silently return wrong results that look
// plausible — the worst kind of bug to ship, because nobody notices for months.
//
// These tests run against a real in-memory SQLite database using the same predicate the
// handler builds, so they verify SQL behaviour rather than a Go reimplementation of it.

func genreTestDB(t *testing.T) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if _, err := db.Exec(`CREATE TABLE items (
		id TEXT PRIMARY KEY, library_id TEXT, title TEXT, genres TEXT)`); err != nil {
		t.Fatalf("create: %v", err)
	}
	rows := []struct{ id, lib, title, genres string }{
		{"m1", "lib_movies", "Action Movie", "Action,Thriller"},
		{"m2", "lib_movies", "Comedy Movie", "Comedy"},
		{"m3", "lib_movies", "Action Comedy", "Action,Comedy"},
		{"m4", "lib_movies", "Docudrama", "Documentary"},
		{"m5", "lib_movies", "Drama Movie", "Drama"},
		{"m6", "lib_movies", "Adventure Epic", "Action & Adventure"},
		{"m7", "lib_movies", "No Genres", ""},
		{"t1", "lib_tv", "TV Drama", "Drama"},
	}
	for _, r := range rows {
		if _, err := db.Exec(`INSERT INTO items(id,library_id,title,genres) VALUES(?,?,?,?)`,
			r.id, r.lib, r.title, r.genres); err != nil {
			t.Fatalf("insert: %v", err)
		}
	}
	return db
}

// buildGenrePredicate mirrors the clause constructed in handleItems.
func buildGenrePredicate(wanted []string, mode string) (string, []any) {
	joiner := " OR "
	if mode == "all" {
		joiner = " AND "
	}
	var preds []string
	var args []any
	for _, g := range wanted {
		preds = append(preds, "(','||IFNULL(genres,'')||',') LIKE ?")
		args = append(args, "%,"+g+",%")
	}
	return "(" + strings.Join(preds, joiner) + ")", args
}

func queryIDs(t *testing.T, db *sql.DB, wanted []string, mode string) []string {
	t.Helper()
	clause, args := buildGenrePredicate(wanted, mode)
	rows, err := db.Query(`SELECT id FROM items WHERE `+clause+` ORDER BY id`, args...)
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			t.Fatalf("scan: %v", err)
		}
		out = append(out, id)
	}
	return out
}

func TestGenreMatchIsExactNotSubstring(t *testing.T) {
	db := genreTestDB(t)
	defer db.Close()

	// "Drama" must NOT match "Documentary" (which contains no Drama) and must NOT match
	// any row merely containing the letters. Only genuine Drama rows.
	got := queryIDs(t, db, []string{"Drama"}, "any")
	want := []string{"m5", "t1"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("Drama matched %v, want %v", got, want)
	}

	// "Action" must NOT match "Action & Adventure" — that is a different genre string.
	got = queryIDs(t, db, []string{"Action"}, "any")
	want = []string{"m1", "m3"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("Action matched %v, want %v (must not match 'Action & Adventure')", got, want)
	}
}

func TestGenreModeAnyWidens(t *testing.T) {
	db := genreTestDB(t)
	defer db.Close()

	got := queryIDs(t, db, []string{"Action", "Comedy"}, "any")
	want := []string{"m1", "m2", "m3"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("any(Action,Comedy) = %v, want %v", got, want)
	}
}

func TestGenreModeAllNarrows(t *testing.T) {
	db := genreTestDB(t)
	defer db.Close()

	// Only the row carrying BOTH.
	got := queryIDs(t, db, []string{"Action", "Comedy"}, "all")
	want := []string{"m3"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("all(Action,Comedy) = %v, want %v", got, want)
	}
}

func TestGenreFilterExcludesItemsWithNoGenres(t *testing.T) {
	db := genreTestDB(t)
	defer db.Close()

	for _, id := range queryIDs(t, db, []string{"Action"}, "any") {
		if id == "m7" {
			t.Error("an item with empty genres must never match a genre filter")
		}
	}
}

func TestGenreFilterHandlesNullGenres(t *testing.T) {
	db := genreTestDB(t)
	defer db.Close()

	// A NULL (not empty-string) genres column must not blow up the IFNULL-wrapped predicate.
	if _, err := db.Exec(`INSERT INTO items(id,library_id,title,genres) VALUES('m8','lib_movies','Null Genres',NULL)`); err != nil {
		t.Fatalf("insert: %v", err)
	}
	got := queryIDs(t, db, []string{"Action"}, "any")
	for _, id := range got {
		if id == "m8" {
			t.Error("NULL genres must not match")
		}
	}
	if len(got) != 2 {
		t.Errorf("expected 2 Action rows, got %v", got)
	}
}
