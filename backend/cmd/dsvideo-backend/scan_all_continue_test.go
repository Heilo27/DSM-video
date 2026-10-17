package main

// TASK-919: one library that cannot be read must not stop the scan of the others. The scan
// used to return at the first library error, so a single unmounted share skipped every
// library configured after it, on every scan, for as long as it stayed down.

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type scanAllFixture struct {
	s                       *Server
	movie, episode, homeVid string
}

// newScanAllFixture configures Movies, TV and Home libraries, one video each, and scans
// them once so every library has rows to protect.
func newScanAllFixture(t *testing.T) *scanAllFixture {
	t.Helper()
	s := scanTestServer(t)
	base := t.TempDir()
	s.cfg.MoviesPath = filepath.Join(base, "movies")
	s.cfg.TVPath = filepath.Join(base, "tv")
	s.cfg.HomePath = filepath.Join(base, "home")
	f := &scanAllFixture{
		s:       s,
		movie:   filepath.Join(s.cfg.MoviesPath, "Up (2009).mp4"),
		episode: filepath.Join(s.cfg.TVPath, "Show", "Season 1", "Show S01E01.mp4"),
		homeVid: filepath.Join(s.cfg.HomePath, "birthday.mp4"),
	}
	for _, p := range []string{f.movie, f.episode, f.homeVid} {
		writeVideo(t, p)
	}
	if err := s.scanAllWithClient(context.Background(), nil); err != nil {
		t.Fatalf("baseline scan: %v", err)
	}
	for _, p := range []string{f.movie, f.episode, f.homeVid} {
		if !itemExists(t, s, p) {
			t.Fatalf("baseline scan did not index %s", p)
		}
	}
	return f
}

// unmount moves a library root away, the way an unmounted share disappears.
func unmount(t *testing.T, root string) {
	t.Helper()
	if err := os.Rename(root, root+".offline"); err != nil {
		t.Fatalf("unmount %s: %v", root, err)
	}
}

func TestScanAllContinuesPastAnUnavailableLibrary(t *testing.T) {
	f := newScanAllFixture(t)
	s := f.s
	// Movies is the FIRST library scanned; the libraries after it gain new files.
	unmount(t, s.cfg.MoviesPath)
	newEpisode := filepath.Join(s.cfg.TVPath, "Show", "Season 1", "Show S01E02.mp4")
	newHome := filepath.Join(s.cfg.HomePath, "graduation.mp4")
	writeVideo(t, newEpisode)
	writeVideo(t, newHome)
	s.mu.Lock()
	s.lastScanAt = time.Time{}
	s.mu.Unlock()

	err := s.scanAllWithClient(context.Background(), nil)

	if err == nil || !strings.Contains(err.Error(), "lib_movies") {
		t.Errorf("scan error = %v, want the unavailable Movies library reported", err)
	}
	if !itemExists(t, s, newEpisode) || !itemExists(t, s, newHome) {
		t.Error("libraries after the unavailable one were not scanned: their new files are missing")
	}
	if !itemExists(t, s, f.movie) || tombstoned(t, s, f.movie) {
		t.Error("the unavailable library's rows were purged; they must be kept (TASK-933)")
	}
	if !itemExists(t, s, f.episode) || !itemExists(t, s, f.homeVid) {
		t.Error("rows of the healthy libraries were lost")
	}
	s.mu.RLock()
	stamped := !s.lastScanAt.IsZero()
	s.mu.RUnlock()
	if !stamped {
		t.Error("lastScanAt not stamped after a full pass: every GET /libraries would start another scan")
	}
}

func TestScanAllReportsEveryFailedLibrary(t *testing.T) {
	f := newScanAllFixture(t)
	s := f.s
	unmount(t, s.cfg.MoviesPath)
	unmount(t, s.cfg.HomePath)
	newEpisode := filepath.Join(s.cfg.TVPath, "Show", "Season 1", "Show S01E02.mp4")
	writeVideo(t, newEpisode)

	err := s.scanAllWithClient(context.Background(), nil)

	if err == nil || !strings.Contains(err.Error(), "lib_movies") || !strings.Contains(err.Error(), "lib_home") {
		t.Errorf("scan error = %v, want both lib_movies and lib_home reported", err)
	}
	if !itemExists(t, s, newEpisode) {
		t.Error("the healthy library between two failed ones was not scanned")
	}
	for _, p := range []string{f.movie, f.homeVid} {
		if !itemExists(t, s, p) || tombstoned(t, s, p) {
			t.Errorf("rows of an unavailable library were purged: %s", p)
		}
	}
}

func TestScanAllHealthyLibrariesReturnNil(t *testing.T) {
	f := newScanAllFixture(t)
	if err := f.s.scanAllWithClient(context.Background(), nil); err != nil {
		t.Errorf("rescan of healthy libraries returned %v, want nil", err)
	}
}

// A cancelled scan (shutdown) reports an error and purges nothing.
func TestScanAllCancelledReturnsErrorAndPurgesNothing(t *testing.T) {
	f := newScanAllFixture(t)
	s := f.s
	newEpisode := filepath.Join(s.cfg.TVPath, "Show", "Season 1", "Show S01E02.mp4")
	writeVideo(t, newEpisode)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := s.scanAllWithClient(ctx, nil); err == nil {
		t.Error("a cancelled scan returned nil")
	}
	for _, p := range []string{f.movie, f.episode, f.homeVid} {
		if !itemExists(t, s, p) || tombstoned(t, s, p) {
			t.Errorf("a cancelled scan purged %s", p)
		}
	}
}
