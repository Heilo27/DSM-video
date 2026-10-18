package main

// TASK-1026 (FRD-000 M1): a Blu-ray rip's BDMV folder is skipped whole, the same rule as a
// DVD's VIDEO_TS (TASK-998). Its BDMV/STREAM/*.m2ts clips are fragments of the disc's
// titles (menus, intros, pieces of the feature joined by the disc's playlists); indexing
// each put a row per clip in the library. A camcorder card's PRIVATE/AVCHD/BDMV/STREAM
// .MTS clips are complete recordings and stay indexed.

import (
	"context"
	"path/filepath"
	"strings"
	"testing"
)

func TestScanSkipsBlurayBDMVFolderAndLogsOnce(t *testing.T) {
	s := scanTestServer(t)
	root := t.TempDir()

	disc := filepath.Join(root, "Movies", "Some Film (Blu-ray)")
	// A second disc with the lower-case name. A separate disc because the test volume may
	// fold case (APFS), which would make bdmv and BDMV one folder.
	other := filepath.Join(root, "Movies", "Other Film")
	fragments := []string{
		filepath.Join(disc, "BDMV", "STREAM", "00000.m2ts"),
		filepath.Join(disc, "BDMV", "STREAM", "00001.m2ts"),
		filepath.Join(disc, "BDMV", "STREAM", "00002.M2TS"),
		filepath.Join(other, "bdmv", "STREAM", "00800.m2ts"),
	}
	loose := filepath.Join(root, "Movies", "Concert", "concert.m2ts") // a lone .m2ts stays indexed
	sibling := filepath.Join(disc, "extras.mp4")
	camcorder := []string{ // AVCHD camcorder card: each clip is a full recording
		filepath.Join(root, "Movies", "Holiday 2024", "PRIVATE", "AVCHD", "BDMV", "STREAM", "00000.MTS"),
		filepath.Join(root, "Movies", "Holiday 2024", "PRIVATE", "AVCHD", "BDMV", "STREAM", "00001.MTS"),
	}
	for _, p := range append(append(append([]string{}, fragments...), camcorder...), loose, sibling) {
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
			t.Errorf("Blu-ray fragment %s was indexed", p)
		}
	}
	for _, p := range camcorder {
		if !itemExists(t, s, p) {
			t.Errorf("camcorder AVCHD clip %s must still be indexed (TASK-990)", p)
		}
	}
	if !itemExists(t, s, loose) {
		t.Error("a loose .m2ts outside a BDMV folder must still be indexed")
	}
	if !itemExists(t, s, sibling) {
		t.Error("a normal video next to a BDMV folder must still be indexed")
	}
	for _, dir := range []string{filepath.Join(disc, "BDMV"), filepath.Join(other, "bdmv")} {
		if n := strings.Count(logs.String(), dir); n != 1 {
			t.Errorf("%s logged %d times over two scans, want exactly once; log:\n%s", dir, n, logs.String())
		}
	}
}
