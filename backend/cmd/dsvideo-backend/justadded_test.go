package main

import (
	"database/sql"
	"path/filepath"
	"testing"

	_ "modernc.org/sqlite"
)

// Just Added is a rail of SHOWS, and the thing every episode of a show reliably shares is
// its folder — not its title, and not its show_name.
//
// The rail shipped keyed on the episode's own title, falling back to show_name when set.
// That holds only while the metadata matched. A real import of "X-Men (Marvel ANIME)" landed
// with show_name NULL on every file and per-episode titles ("… Episode 12 Destiny Bond",
// "… Episode 11 Revenge End"), so each of the nine episodes got a distinct key and the one
// series took nine of the rail's 24 slots — burying the films added the same week, which is
// the exact failure the dedup exists to prevent.
//
// The fix routes through the codebase's single answer for show identity
// (showFolderFromPath → resolveFolderShowNames → showGroupKey), so the rail groups the same
// way every list endpoint does.

const justAddedSchema = `
CREATE TABLE items(
  id TEXT PRIMARY KEY, library_id TEXT, type TEXT, title TEXT,
  year INT, path TEXT, duration_seconds INT, added_at TEXT, updated_at TEXT,
  rating REAL, poster_path TEXT, backdrop_path TEXT, show_name TEXT,
  season_number INT, episode_number INT);
`

type justAddedRow struct {
	id, typ, title, path string
	showName             any // nil for an unmatched episode
	added                string
}

func newJustAddedServer(t *testing.T, rows []justAddedRow) *Server {
	t.Helper()
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	if _, err := db.Exec(justAddedSchema); err != nil {
		t.Fatalf("schema: %v", err)
	}
	for _, r := range rows {
		lib := "lib_movies"
		if r.typ == "episode" {
			lib = "lib_tv"
		}
		if _, err := db.Exec(
			`INSERT INTO items(id, library_id, type, title, path, show_name, added_at)
			 VALUES(?,?,?,?,?,?,?)`,
			r.id, lib, r.typ, r.title, r.path, r.showName, r.added); err != nil {
			t.Fatalf("insert %s: %v", r.id, err)
		}
	}
	return &Server{cfg: Config{TVPath: testTVRoot}, db: db}
}

func titlesOf(items []map[string]any) []string {
	out := make([]string, 0, len(items))
	for _, it := range items {
		out = append(out, it["title"].(string))
	}
	return out
}

// The reported failure, reduced: nine episodes of one unmatched show, added newest, plus
// three films added just before. All three films must survive onto the rail.
func TestJustAddedCollapsesUnmatchedEpisodesOntoOneShow(t *testing.T) {
	var rows []justAddedRow
	// Newest: nine episodes of one show, no metadata match at all.
	for i := 9; i >= 1; i-- {
		rows = append(rows, justAddedRow{
			id:    string(rune('a'+i)) + "_ep",
			typ:   "episode",
			title: "X-Men (Marvel ANIME) Episode 0" + string(rune('0'+i)) + " Whatever",
			path:  testTVRoot + "/X-Men Marvel ANIME/ep0" + string(rune('0'+i)) + ".mkv",
			added: "2026-09-1" + string(rune('0'+i)) + "T00:00:00Z",
		})
	}
	// Older: three films.
	rows = append(rows,
		justAddedRow{id: "m1", typ: "movie", title: "Megalopolis", path: "/movies/a.mkv", added: "2026-09-05T00:00:00Z"},
		justAddedRow{id: "m2", typ: "movie", title: "Pressure", path: "/movies/b.mkv", added: "2026-09-04T00:00:00Z"},
		justAddedRow{id: "m3", typ: "movie", title: "Top Gun: Maverick", path: "/movies/c.mkv", added: "2026-09-03T00:00:00Z"},
	)

	s := newJustAddedServer(t, rows)
	items, err := s.queryJustAdded("")
	if err != nil {
		t.Fatalf("queryJustAdded: %v", err)
	}

	got := titlesOf(items)
	if len(got) != 4 {
		t.Fatalf("rail has %d entries %v, want 4 (one show + three films)", len(got), got)
	}
	// The show occupies exactly one slot, labelled by its folder since nothing matched.
	if got[0] != "X-Men Marvel ANIME" {
		t.Errorf("first entry = %q, want the show labelled by its folder", got[0])
	}
	for _, want := range []string{"Megalopolis", "Pressure", "Top Gun: Maverick"} {
		found := false
		for _, g := range got {
			if g == want {
				found = true
			}
		}
		if !found {
			t.Errorf("film %q was buried off the rail; got %v", want, got)
		}
	}
}

// A part-matched folder is still one show. Metadata lands per episode, so a folder routinely
// holds some episodes that matched and some that did not; keying each on its own show_name
// splits one show into two rail entries.
func TestJustAddedPartMatchedFolderIsOneEntry(t *testing.T) {
	s := newJustAddedServer(t, []justAddedRow{
		{id: "e1", typ: "episode", title: "Ep 3", path: testTVRoot + "/Shameless/e3.mkv",
			showName: "Shameless", added: "2026-09-10T00:00:00Z"},
		{id: "e2", typ: "episode", title: "Ep 2", path: testTVRoot + "/Shameless/e2.mkv",
			added: "2026-09-09T00:00:00Z"}, // no match
		{id: "e3", typ: "episode", title: "Ep 1", path: testTVRoot + "/Shameless/e1.mkv",
			showName: "Shameless", added: "2026-09-08T00:00:00Z"},
	})

	items, err := s.queryJustAdded("")
	if err != nil {
		t.Fatalf("queryJustAdded: %v", err)
	}
	got := titlesOf(items)
	if len(got) != 1 {
		t.Fatalf("rail has %d entries %v, want 1 — a part-matched folder is one show", len(got), got)
	}
	if got[0] != "Shameless" {
		t.Errorf("title = %q, want the resolved show name", got[0])
	}
}

// A show split across two folders that both carry the same show_name is one show, the same
// way every list endpoint treats it.
func TestJustAddedMergesSplitFoldersOfOneShow(t *testing.T) {
	s := newJustAddedServer(t, []justAddedRow{
		{id: "d1", typ: "episode", title: "S02E01", path: testTVRoot + "/Daredevil (2015)/a.mkv",
			showName: "Daredevil", added: "2026-09-10T00:00:00Z"},
		{id: "d2", typ: "episode", title: "S01E01", path: testTVRoot + "/Daredevil/b.mkv",
			showName: "Daredevil", added: "2026-09-09T00:00:00Z"},
	})

	items, err := s.queryJustAdded("")
	if err != nil {
		t.Fatalf("queryJustAdded: %v", err)
	}
	if got := titlesOf(items); len(got) != 1 {
		t.Fatalf("rail has %d entries %v, want 1 — both folders are Daredevil", len(got), got)
	}
}

// Two genuinely different shows stay two entries. The dedup must not over-merge.
func TestJustAddedKeepsDistinctShowsSeparate(t *testing.T) {
	s := newJustAddedServer(t, []justAddedRow{
		{id: "a1", typ: "episode", title: "Ep", path: testTVRoot + "/Attack on Titan/a.mkv",
			showName: "Attack on Titan", added: "2026-09-10T00:00:00Z"},
		{id: "r1", typ: "episode", title: "Ep", path: testTVRoot + "/Rick and Morty/a.mkv",
			showName: "Rick and Morty", added: "2026-09-09T00:00:00Z"},
		// Same episode TITLE as the two above, different folder, no metadata — must not
		// fold into either of them.
		{id: "u1", typ: "episode", title: "Ep", path: testTVRoot + "/Some Unmatched Show/a.mkv",
			added: "2026-09-08T00:00:00Z"},
	})

	items, err := s.queryJustAdded("")
	if err != nil {
		t.Fatalf("queryJustAdded: %v", err)
	}
	if got := titlesOf(items); len(got) != 3 {
		t.Fatalf("rail has %d entries %v, want 3 distinct shows", len(got), got)
	}
}

// Two films that share a title are two films — the movie path must not group by folder.
func TestJustAddedFilmsAreTheirOwnEntries(t *testing.T) {
	s := newJustAddedServer(t, []justAddedRow{
		{id: "m1", typ: "movie", title: "Avatar", path: "/movies/Avatar (2009)/a.mkv", added: "2026-09-10T00:00:00Z"},
		{id: "m2", typ: "movie", title: "Borg vs McEnroe", path: "/movies/Borg/b.mkv", added: "2026-09-09T00:00:00Z"},
	})

	items, err := s.queryJustAdded("")
	if err != nil {
		t.Fatalf("queryJustAdded: %v", err)
	}
	if got := titlesOf(items); len(got) != 2 {
		t.Fatalf("rail has %d entries %v, want 2 films", len(got), got)
	}
}

// Newest first, and the entry for a show carries the newest episode's id so the card opens
// on something that exists.
func TestJustAddedOrdersNewestFirst(t *testing.T) {
	s := newJustAddedServer(t, []justAddedRow{
		{id: "old", typ: "movie", title: "Old Film", path: "/movies/o.mkv", added: "2026-01-01T00:00:00Z"},
		{id: "new_ep", typ: "episode", title: "Newest", path: testTVRoot + "/Show/b.mkv",
			showName: "Show", added: "2026-09-16T00:00:00Z"},
		{id: "old_ep", typ: "episode", title: "Older", path: testTVRoot + "/Show/a.mkv",
			showName: "Show", added: "2026-09-01T00:00:00Z"},
	})

	items, err := s.queryJustAdded("")
	if err != nil {
		t.Fatalf("queryJustAdded: %v", err)
	}
	if len(items) != 2 {
		t.Fatalf("rail has %d entries %v, want 2", len(items), titlesOf(items))
	}
	if items[0]["title"] != "Show" {
		t.Errorf("first = %q, want the newest addition", items[0]["title"])
	}
	if items[0]["id"] != "new_ep" {
		t.Errorf("show id = %q, want the newest episode %q", items[0]["id"], "new_ep")
	}
}
