package main

// TASK-1025 (Rule 9): the conversion scripts carried their own copies of "which files are
// videos", and the copies had drifted: tools/convert-library.sh listed 12 extensions,
// scripts/sprint-convert.sh 7, the scanner 22, and neither script knew the disc-rip rule.
// `dsvideo-backend --list-video-files` now answers from the scanner's own filter, and the
// scripts take their list from it.

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// The listing is exactly the set of files a scan indexes: every file in a mixed tree is
// either listed and indexed, or neither.
func TestListVideoFilesIsExactlyWhatTheScannerIndexes(t *testing.T) {
	s := scanTestServer(t)
	root := t.TempDir()
	s.cfg.OriginalsDir = filepath.Join(root, "Backups Here") // a custom DSVIDEO_ORIGINALS_DIR

	files := []string{
		"Film/film.mkv", "Film/film.MP4", "Film/old.wmv", "Film/clip.webm", "Film/home.vob",
		"Film/film.iso",                               // known format, not indexed
		"Film/film.nfo", "Film/film.srt", "notes.txt", // not video
		"Film/.film.converting.mp4",     // in-flight conversion temp
		"DVD Rip/VIDEO_TS/VTS_01_1.VOB", // disc-rip fragments
		"Bluray Rip/BDMV/STREAM/00001.m2ts",
		"Holiday/PRIVATE/AVCHD/BDMV/STREAM/00000.MTS", // camcorder clip: indexed
		"_dsvideo_originals/Film/film.avi",            // backup tree, conventional name
		"Backups Here/Film/film.avi",                  // backup tree, configured dir
		"Concert/concert.m2ts",
	}
	for _, f := range files {
		writeVideo(t, filepath.Join(root, f))
	}

	var out, errs bytes.Buffer
	if err := listVideoFiles(&out, &errs, []string{root}, s.cfg.OriginalsDir); err != nil {
		t.Fatalf("listVideoFiles: %v (stderr %q)", err, errs.String())
	}
	listed := map[string]bool{}
	for _, p := range strings.Split(strings.TrimSuffix(out.String(), "\x00"), "\x00") {
		if p != "" {
			listed[p] = true
		}
	}

	if err := s.scanLibraryWithClient(context.Background(), "lib_movies", "movies", root, nil); err != nil {
		t.Fatalf("scan: %v", err)
	}
	var indexed []string
	for _, f := range files {
		p := filepath.Join(root, f)
		inDB := itemExists(t, s, p)
		if inDB {
			indexed = append(indexed, f)
		}
		if listed[p] != inDB {
			t.Errorf("%s: listed=%v but indexed=%v; the listing must be the scanner's filter", f, listed[p], inDB)
		}
	}
	if len(listed) != len(indexed) {
		t.Errorf("listed %d files, scanner indexed %d", len(listed), len(indexed))
	}

	// And the set itself, so the agreement above is not two empty lists agreeing.
	want := []string{"Concert/concert.m2ts", "Film/clip.webm", "Film/film.MP4", "Film/film.mkv",
		"Film/home.vob", "Film/old.wmv", "Holiday/PRIVATE/AVCHD/BDMV/STREAM/00000.MTS"}
	sort.Strings(indexed)
	if strings.Join(indexed, "|") != strings.Join(want, "|") {
		t.Errorf("indexed %v, want %v", indexed, want)
	}
}

// A root that cannot be read is an error, so a script never takes a failed listing for an
// empty library and quietly converts nothing (or, worse, half of it).
func TestListVideoFilesFailsOnAMissingRoot(t *testing.T) {
	var out, errs bytes.Buffer
	missing := filepath.Join(t.TempDir(), "not-mounted")
	if err := listVideoFiles(&out, &errs, []string{missing}, ""); err == nil {
		t.Fatal("a missing root must be an error")
	}
	if err := listVideoFiles(&out, &errs, nil, ""); err == nil {
		t.Fatal("no roots must be an error, not an empty listing")
	}
}

// The scripts must take their list from the backend and carry no extension list of their
// own. A `*.mkv`-style glob for any extension the scanner knows is a second copy.
func TestConversionScriptsCarryNoExtensionListOfTheirOwn(t *testing.T) {
	var exts []string
	for ext := range scanVideoExt {
		exts = append(exts, regexp.QuoteMeta(strings.TrimPrefix(ext, ".")))
	}
	glob := regexp.MustCompile(`(?i)\*\.(` + strings.Join(exts, "|") + `)\b`)
	for _, rel := range []string{"../../../tools/convert-library.sh", "../../../scripts/sprint-convert.sh"} {
		b, err := os.ReadFile(rel)
		if err != nil {
			t.Fatalf("read %s: %v", rel, err)
		}
		src := string(b)
		if !strings.Contains(src, "--list-video-files") {
			t.Errorf("%s does not take its file list from dsvideo-backend --list-video-files", rel)
		}
		for i, line := range strings.Split(src, "\n") {
			if m := glob.FindString(line); m != "" {
				t.Errorf("%s:%d carries its own extension glob %q: %s", rel, i+1, m, strings.TrimSpace(line))
			}
		}
	}
}
