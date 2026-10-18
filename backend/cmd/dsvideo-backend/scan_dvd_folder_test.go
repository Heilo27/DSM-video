package main

// TASK-998 (FRD-000 M1): a DVD rip folder (VIDEO_TS / AUDIO_TS) is skipped whole. Its
// .VOB files are title fragments (VTS_01_1.VOB ... VTS_01_4.VOB) that only play as a
// sequence; indexing each as a "movie" put a dozen unplayable rows in the library.

import (
	"context"
	"path/filepath"
	"strings"
	"testing"
)

func TestScanSkipsDVDFolderAndLogsOnce(t *testing.T) {
	s := scanTestServer(t)
	root := t.TempDir()

	dvd := filepath.Join(root, "Movies", "Some Film (DVD)")
	fragments := []string{
		filepath.Join(dvd, "VIDEO_TS", "VTS_01_1.VOB"),
		filepath.Join(dvd, "VIDEO_TS", "VTS_01_2.VOB"),
		// A second disc with the lower-case name, nested. A separate disc because the test
		// volume may fold case (APFS), which would make video_ts and VIDEO_TS one folder.
		filepath.Join(root, "Movies", "Other Film", "video_ts", "nested", "VTS_02_1.vob"),
		filepath.Join(dvd, "AUDIO_TS", "ATS_01_1.VOB"),
	}
	loose := filepath.Join(root, "Movies", "Home Movie", "home.vob") // a lone .vob stays indexed
	sibling := filepath.Join(dvd, "extras.mp4")
	for _, p := range append(append([]string{}, fragments...), loose, sibling) {
		writeVideo(t, p)
	}
	logs := captureLog(t)

	for i := 0; i < 2; i++ {
		if err := s.scanLibraryWithClient(context.Background(), "lib_movies", "movies", root, nil); err != nil {
			t.Fatalf("scan %d: %v", i, err)
		}
	}
	for _, p := range fragments {
		if itemExists(t, s, p) {
			t.Errorf("DVD fragment %s was indexed", p)
		}
	}
	if !itemExists(t, s, loose) {
		t.Error("a loose .vob outside VIDEO_TS/AUDIO_TS must still be indexed (TASK-990)")
	}
	if !itemExists(t, s, sibling) {
		t.Error("a normal video next to a VIDEO_TS folder must still be indexed")
	}
	for _, dir := range []string{
		filepath.Join(dvd, "VIDEO_TS"), filepath.Join(root, "Movies", "Other Film", "video_ts"), filepath.Join(dvd, "AUDIO_TS"),
	} {
		if n := strings.Count(logs.String(), dir); n != 1 {
			t.Errorf("%s logged %d times over two scans, want exactly once; log:\n%s", dir, n, logs.String())
		}
	}
}
