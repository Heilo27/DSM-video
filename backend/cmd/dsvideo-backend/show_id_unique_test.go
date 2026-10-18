package main

import (
	"database/sql"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

// A show id must be unique, by construction rather than by luck.
//
// The id was the folder name, and one folder can legitimately hold TWO shows: Daredevil/
// carries 39 episodes of "Marvel's Daredevil" and 9 of "Daredevil: Born Again". Both groups
// emitted the same id, and a client keyed on id renders one and silently loses the other.
// That is how Star Trek: The Next Generation disappeared from a real Apple TV — a collision
// elsewhere in the list ate it, with nothing logged at any layer.
//
// Five folders in the live library are ambiguous this way, so this is not a hypothetical.

func TestSplitShowIDLeavesBareFolderIDsAlone(t *testing.T) {
	// Every id persisted before qualification existed is a bare folder name, and must keep
	// resolving exactly as it did — this is what stops the change breaking saved state.
	folder, group := splitShowID("Daredevil")
	if folder != "Daredevil" || group != "" {
		t.Fatalf("a bare id must pass through unchanged, got folder=%q group=%q", folder, group)
	}

	// Including folder names with characters that look structural but are not.
	for _, id := range []string{"NCIS", "Star Trek: The Next Generation", "X-Men - ANIME", "S.H.I.E.L.D."} {
		f, g := splitShowID(id)
		if f != id || g != "" {
			t.Errorf("splitShowID(%q) = (%q, %q), want the id unchanged with no qualifier", id, f, g)
		}
	}
}

func TestSplitShowIDSeparatesAQualifiedID(t *testing.T) {
	folder, group := splitShowID("Daredevil::daredevil: born again")
	if folder != "Daredevil" {
		t.Errorf("folder = %q, want %q", folder, "Daredevil")
	}
	if group != "daredevil: born again" {
		t.Errorf("group = %q, want %q", group, "daredevil: born again")
	}

	// The group key itself may contain a colon — splitting must use the FIRST separator
	// only, or a show named "X: Y" would lose part of its key.
	f, g := splitShowID("Folder::star trek: deep space nine")
	if f != "Folder" || g != "star trek: deep space nine" {
		t.Errorf("split on the first separator only: got (%q, %q)", f, g)
	}
}

// A bare id must produce NO extra predicate, so the common query stays byte-identical.
func TestShowGroupWhereIsEmptyForABareID(t *testing.T) {
	where, args := showGroupWhere("Daredevil")
	if where != "" || len(args) != 0 {
		t.Fatalf("a bare id must add no predicate, got where=%q args=%v", where, args)
	}
}

// A qualified id must narrow on show_name — the only thing that distinguishes two shows
// sharing a folder, since their paths cannot.
func TestShowGroupWhereNarrowsOnShowNameForAQualifiedID(t *testing.T) {
	where, args := showGroupWhere("Daredevil::daredevil: born again")
	if where == "" {
		t.Fatal("a qualified id must add a narrowing predicate")
	}
	if len(args) != 1 || args[0] != "daredevil: born again" {
		t.Fatalf("args = %v, want the group key alone", args)
	}
	// It must AND onto an existing folder predicate, never replace it: show_name is not
	// unique across the library, so matching on it alone would merge different shows.
	if len(where) < 5 || where[:5] != " AND " {
		t.Errorf("predicate must AND onto the folder match, got %q", where)
	}
}

// The round trip: a qualified id a client persisted (the list emitted them before TASK-1027)
// must still resolve back to that folder plus the group that produced it.
func TestQualifiedIDRoundTripsToItsFolderAndGroup(t *testing.T) {
	const folder = "Daredevil"
	const groupKey = "daredevil: born again"
	id := folder + showIDGroupSeparator + groupKey

	gotFolder, gotGroup := splitShowID(id)
	if gotFolder != folder || gotGroup != groupKey {
		t.Fatalf("round trip lost information: (%q, %q)", gotFolder, gotGroup)
	}

	where, args := showGroupWhere(id)
	if where == "" || args[0] != groupKey {
		t.Fatal("the resolved group key did not reach the query")
	}
}

// The separator must not appear in a real folder name, or a legitimate folder would be
// mis-split into a folder plus a bogus qualifier.
func TestSeparatorCannotBeConfusedWithARealFolderName(t *testing.T) {
	if showIDGroupSeparator != "::" {
		t.Fatalf("separator changed to %q — update this test and confirm it still cannot "+
			"appear in a folder name", showIDGroupSeparator)
	}
	// Every ambiguous folder in the live library, none of which contain the separator.
	for _, folder := range []string{
		"Daredevil", "Marvel's What If", "The Peripheral (2022)",
		"X-Men - ANIME Series and CARTOON Series", "Marvel's Agents of SHIELD",
	} {
		if f, g := splitShowID(folder); f != folder || g != "" {
			t.Errorf("real folder %q was mis-split into (%q, %q)", folder, f, g)
		}
	}
}

// TASK-1027. The list's ids are unique because grouping is per FOLDER, which is why the
// "folder::key" emission was deleted as unreachable: resolveFolderShowNames picks one name
// per folder, so a folder can never back two groups. This pins that invariant at both
// layers. If grouping ever becomes per-episode again, a folder holding two shows would put
// two groups under one folder name; this fails then, and the qualifier has to come back.
func TestEveryFolderBacksOneShowAndIDsAreBareFolders(t *testing.T) {
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	if _, err := db.Exec(showMergeSchema); err != nil {
		t.Fatalf("schema: %v", err)
	}
	seedOwnerProfile(t, db, "u1")
	seed := []struct{ path, show string }{
		// Two shows in one folder: the case the qualifier was written for.
		{"/Daredevil/S01E01.mkv", "Marvel's Daredevil"},
		{"/Daredevil/S01E02.mkv", "Marvel's Daredevil"},
		{"/Daredevil/S01E03.mkv", "Marvel's Daredevil"},
		{"/Daredevil/S01E04.mkv", "Daredevil: Born Again"},
		{"/Daredevil/S01E05.mkv", "Daredevil: Born Again"},
		{"/Born Again/S01E06.mkv", "Daredevil: Born Again"},
		// Part-matched folder with a season subfolder, unmatched folder, root-level file.
		{"/Shameless/Season 1/S01E01.mkv", "Shameless"},
		{"/Shameless/Season 1/S01E02.mkv", ""},
		{"/Home Movies/S01E01.mkv", ""},
		{"/Loose Episode S01E01.mkv", ""},
	}
	ins := `INSERT INTO items(id, library_id, type, title, path, show_name, season_number,
	        episode_number, added_at, change_seq) VALUES(?,?,?,?,?,?,?,?,?,?)`
	refs := make([]episodeRef, 0, len(seed))
	for i, r := range seed {
		show := sql.NullString{String: r.show, Valid: r.show != ""}
		refs = append(refs, episodeRef{Path: testTVRoot + r.path, ShowName: show})
		if _, err := db.Exec(ins, fmt.Sprintf("ep%d", i), "lib_tv", "episode", "Episode",
			testTVRoot+r.path, show, 1, i+1, "2024-01-01T00:00:00Z", i+1); err != nil {
			t.Fatalf("insert %s: %v", r.path, err)
		}
	}

	// Grouping layer: one key per folder, whatever mix of show names the folder holds.
	keyOf := map[string]string{}
	for _, g := range groupEpisodesByShow(refs, testTVRoot+"/") { // the root as the handler passes it
		if prev, ok := keyOf[g.Folder]; ok && prev != g.Key {
			t.Errorf("folder %q grouped under two keys, %q and %q", g.Folder, prev, g.Key)
		}
		keyOf[g.Folder] = g.Key
	}

	// List layer: every id a bare folder name, none repeated, no episode lost.
	s := &Server{cfg: Config{TVPath: testTVRoot}, db: db}
	seen, total := map[string]bool{}, 0
	for _, sh := range listShows(t, s, "u1") {
		if strings.Contains(sh.ID, showIDGroupSeparator) {
			t.Errorf("id %q is qualified; every folder backs one show, so ids are bare folders", sh.ID)
		}
		if _, ok := keyOf[sh.ID]; !ok {
			t.Errorf("id %q is not the folder of any episode", sh.ID)
		}
		if seen[sh.ID] {
			t.Errorf("id %q listed twice", sh.ID)
		}
		seen[sh.ID] = true
		total += sh.EpisodeCount
	}
	if total != len(seed) {
		t.Errorf("list counts %d episodes, want %d: a group was dropped", total, len(seed))
	}
}
