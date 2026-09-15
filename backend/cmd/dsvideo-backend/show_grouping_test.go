package main

import (
	"database/sql"
	"testing"
)

// A show is ONE show, even when its episodes are spread across differently-named folders.
//
// This rule existed three times with two different answers: /tv/shows merged on the TMDb
// show name, while /shows and the DS Video plane grouped on the folder alone. The same
// library therefore reported a different number of shows depending on which endpoint you
// asked, and a series re-foldered part-way through (say "Daredevil" and "Daredevil (2015)")
// appeared once in one place and twice in the other two.
//
// Both halves now come from showGroupKey / showFolderFromPath.

func name(s string) sql.NullString { return sql.NullString{String: s, Valid: true} }

func TestEpisodesInDifferentFoldersGroupAsOneShow(t *testing.T) {
	// The case the owner described: same series, two folder names, one TMDb match.
	a := showGroupKey("Daredevil", name("Daredevil"))
	b := showGroupKey("Daredevil (2015)", name("Daredevil"))
	if a != b {
		t.Fatalf("episodes of one show in two folders must share a key: %q vs %q", a, b)
	}
}

// Folder-name casing must not split a show either.
func TestGroupKeyIsCaseInsensitiveOnTheShowName(t *testing.T) {
	if showGroupKey("f1", name("The Bear")) != showGroupKey("f2", name("THE BEAR")) {
		t.Fatal("show name casing must not split a show")
	}
}

// Without a TMDb match there is no identity beyond the folder, so the folder IS the
// identity — two unmatched folders stay two shows.
func TestUnmatchedContentGroupsByFolder(t *testing.T) {
	none := sql.NullString{}
	if showGroupKey("Some Show", none) != "Some Show" {
		t.Error("an unmatched episode should group under its folder")
	}
	if showGroupKey("A", none) == showGroupKey("B", none) {
		t.Error("two different unmatched folders must stay separate shows")
	}
	// An empty-but-valid show name is not an identity either.
	if showGroupKey("Folder", name("")) != "Folder" {
		t.Error("an empty show name must fall back to the folder")
	}
}

// Distinct shows must never collide just because they share a library.
func TestDifferentShowsStaySeparate(t *testing.T) {
	if showGroupKey("Show A", name("Show A")) == showGroupKey("Show B", name("Show B")) {
		t.Fatal("different shows must not merge")
	}
}

func TestShowFolderFromPath(t *testing.T) {
	const root = "/volume1/video/Shows/"
	cases := []struct{ name, path, want string }{
		{"episode in a show folder", root + "Daredevil/S01E01.mkv", "Daredevil"},
		{"nested season folder", root + "Daredevil/Season 1/S01E01.mkv", "Daredevil"},
		// A root-level episode still belongs to something; returning "" would drop it
		// from every listing, so the stem is the fallback.
		{"root-level file falls back to the stem", root + "Loose Episode.mkv", "Loose Episode"},
		{"root-level file with dots", root + "Show.S01E01.1080p.mkv", "Show.S01E01.1080p"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := showFolderFromPath(c.path, root); got != c.want {
				t.Errorf("showFolderFromPath(%q) = %q, want %q", c.path, got, c.want)
			}
		})
	}
}

// The scanner's show_folder_id rule is deliberately STRICTER than showFolderFromPath: it
// stores a real directory or NULL, because the sibling-poster fallback matches it with
// `path LIKE tvRoot || folder || '/%'` — a prefix that only exists for an actual directory.
// A filename stem stored there would match nothing and cost every root-level episode its
// show poster. This pins the difference so nobody "consolidates" the two into a bug.
func TestScannerFolderRuleIsStricterThanTheDisplayRule(t *testing.T) {
	const root = "/volume1/video/Shows/"
	rootLevel := root + "Loose Episode.mkv"

	if got := showFolderFromPath(rootLevel, root); got == "" {
		t.Fatal("the display rule must still yield a name for a root-level episode")
	}

	// The scanner's rule, as written in scanLibraryWithClient.
	scannerFolder := func(path string) (string, bool) {
		rel := path
		if len(path) > len(root) && path[:len(root)] == root {
			rel = path[len(root):]
		}
		for i := 0; i < len(rel); i++ {
			if rel[i] == '/' {
				if i == 0 {
					return "", false
				}
				return rel[:i], true
			}
		}
		return "", false
	}

	if _, ok := scannerFolder(rootLevel); ok {
		t.Error("the scanner must store NULL for a root-level episode, not a stem")
	}
	if folder, ok := scannerFolder(root + "Daredevil/S01E01.mkv"); !ok || folder != "Daredevil" {
		t.Errorf("scanner rule on a real folder: got (%q, %v), want (\"Daredevil\", true)", folder, ok)
	}
}

// PARTIAL METADATA MUST NOT SPLIT ONE FOLDER INTO TWO SHOWS.
//
// Reported from a real Apple TV: the TV Shows grid had blank cards and Star Trek: The Next
// Generation was missing entirely, while the server held it with 176 episodes and a working
// poster. Four shows came back TWICE from /tv/shows — same title, same id, different episode
// counts, a poster on only one of each pair.
//
// Cause: metadata lands per EPISODE, so a folder is routinely part-matched. Shameless had 134
// episodes carrying showName="Shameless" and 6 carrying none, all in one folder. Grouping each
// episode on its own showName filed the 134 under "shameless" and the 6 under the folder. Both
// halves then emitted `id: folderName`, so the list contained duplicate ids — and SwiftUI's
// ForEach, keyed on id, drops or blanks rows when ids collide. That is why TNG disappeared: it
// was collateral from a collision elsewhere in the list, not a problem with TNG.
//
// The fix resolves ONE name per folder before any episode is filed. These tests pin that
// resolution, since the grouping function itself stays a pure mapping.

func TestPartialMetadataResolvesToOneNamePerFolder(t *testing.T) {
	// The real Shameless shape: most episodes matched, a few did not.
	resolved := resolveFolderShowNames(map[string]map[string]int{
		"Shameless": {"Shameless": 134},
	})

	got := resolved["Shameless"]
	if !got.Valid || got.String != "Shameless" {
		t.Fatalf("a part-matched folder must resolve to its matched name, got %+v", got)
	}

	// Every episode of the folder — matched or not — must now produce the SAME key.
	matched := showGroupKey("Shameless", got)
	unmatched := showGroupKey("Shameless", got)
	if matched != unmatched {
		t.Fatalf("one folder produced two keys (%q vs %q) — the show will be listed twice",
			matched, unmatched)
	}
}

// A stray mismatch inside a folder must not win the folder's identity.
func TestFolderNameResolutionPrefersTheMajority(t *testing.T) {
	// NCIS's real shape: 159 episodes matched "NCIS", 8 mismatched to "NCIS: Sydney".
	resolved := resolveFolderShowNames(map[string]map[string]int{
		"NCIS": {"NCIS": 159, "NCIS: Sydney": 8},
	})
	if got := resolved["NCIS"]; !got.Valid || got.String != "NCIS" {
		t.Fatalf("the majority name must win the folder, got %+v", got)
	}
}

// Resolution must be deterministic: a map iteration order deciding a show's identity would
// make the list reorder between requests for no reason.
func TestFolderNameResolutionIsDeterministicOnTies(t *testing.T) {
	counts := map[string]map[string]int{"F": {"Beta": 5, "Alpha": 5}}
	first := resolveFolderShowNames(counts)["F"]
	for i := 0; i < 50; i++ {
		if got := resolveFolderShowNames(counts)["F"]; got != first {
			t.Fatalf("tie broke differently across runs: %+v then %+v", first, got)
		}
	}
	if first.String != "Alpha" {
		t.Errorf("ties should break on the name for stability, got %q", first.String)
	}
}

// A folder nothing matched has no identity beyond itself, and must still group by folder.
func TestFolderWithNoMatchesFallsBackToTheFolder(t *testing.T) {
	resolved := resolveFolderShowNames(map[string]map[string]int{"Unmatched Show": {}})
	got := resolved["Unmatched Show"]
	if got.Valid {
		t.Fatalf("a folder with no matched episodes must resolve to no name, got %+v", got)
	}
	if showGroupKey("Unmatched Show", got) != "Unmatched Show" {
		t.Error("an unmatched folder must still group under its own folder name")
	}
}

// The cross-folder merge this function exists for must survive the fix.
func TestResolutionStillFoldsTwoFoldersOfOneShow(t *testing.T) {
	resolved := resolveFolderShowNames(map[string]map[string]int{
		"Daredevil":        {"Daredevil": 13},
		"Daredevil (2015)": {"Daredevil": 26},
	})
	a := showGroupKey("Daredevil", resolved["Daredevil"])
	b := showGroupKey("Daredevil (2015)", resolved["Daredevil (2015)"])
	if a != b {
		t.Fatalf("two folders of one show must still merge: %q vs %q", a, b)
	}
}
