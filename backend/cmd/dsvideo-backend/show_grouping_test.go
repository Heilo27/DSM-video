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
