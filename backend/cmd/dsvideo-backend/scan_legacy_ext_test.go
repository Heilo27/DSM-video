package main

// TASK-990 (FRD-000 M1): a title visible in File Station must be findable. The scanner used
// to drop .wmv .mpg .mpeg .m2ts .mts .flv .vob .3gp without a trace.

import (
	"context"
	"path/filepath"
	"strings"
	"testing"
)

func TestScanIndexesLegacyVideoContainers(t *testing.T) {
	s := scanTestServer(t)
	root := t.TempDir()
	wanted := []string{".wmv", ".mpg", ".mpeg", ".m2ts", ".mts", ".flv", ".vob", ".3gp",
		".rm", ".rmvb", ".divx", ".asf", ".ogv", ".ogm", ".f4v"} // last seven: TASK-1002
	var videos, ignored []string
	for _, ext := range wanted {
		videos = append(videos, filepath.Join(root, "Movies", "clip"+ext))
	}
	for _, name := range []string{"notes.txt", "movie.nfo", "movie.srt"} {
		ignored = append(ignored, filepath.Join(root, "Movies", name))
	}
	for _, p := range append(append([]string{}, videos...), ignored...) {
		writeVideo(t, p)
	}

	if err := s.scanLibraryWithClient(context.Background(), "lib_movies", "movies", root, nil); err != nil {
		t.Fatalf("scan: %v", err)
	}
	for _, p := range videos {
		if !itemExists(t, s, p) {
			t.Errorf("%s yielded no item row", filepath.Base(p))
		}
	}
	for _, p := range ignored {
		if itemExists(t, s, p) {
			t.Errorf("non-video %s yielded an item row", filepath.Base(p))
		}
	}
}

func TestScanLogsUnsupportedVideoExtensionOnce(t *testing.T) {
	s := scanTestServer(t)
	root := t.TempDir()
	skipped := filepath.Join(root, "Movies", "disc.iso")
	writeVideo(t, skipped)
	logs := captureLog(t)

	for i := 0; i < 2; i++ {
		if err := s.scanLibraryWithClient(context.Background(), "lib_movies", "movies", root, nil); err != nil {
			t.Fatalf("scan %d: %v", i, err)
		}
	}
	if itemExists(t, s, skipped) {
		t.Error("an unsupported container must not get an item row")
	}
	if n := strings.Count(logs.String(), skipped); n != 1 {
		t.Errorf("skipped path logged %d times over two scans, want exactly once; log:\n%s", n, logs.String())
	}
}
