package transcode

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// The inactivity reaper was dead code: cleanupInactive called GetSession, which
// stamps LastAccess = time.Now() before returning, so the very next line's
// `LastAccess.Before(now - InactivityTimeout)` could never be true. Abandoned HLS
// sessions were therefore never evicted, and each one held an g.active slot for the
// life of the process — once every slot was held, all playback returned
// transcode_busy until the server was restarted.
//
// These tests pin the read-only accessors that fix it.

// TestLastAccessOfDoesNotRefresh is the core regression: reading a session's
// last-access time must NOT stamp it. If this fails, the reaper is dead again.
func TestLastAccessOfDoesNotRefresh(t *testing.T) {
	g := NewHLSGenerator(HLSConfig{})

	stale := time.Now().Add(-3 * time.Hour)
	g.sessions["s1"] = &HLSSession{SessionID: "s1", LastAccess: stale}

	got, ok := g.LastAccessOf("s1")
	if !ok {
		t.Fatal("LastAccessOf: session not found")
	}
	if !got.Equal(stale) {
		t.Fatalf("LastAccessOf refreshed LastAccess: got %v, want %v", got, stale)
	}

	// And the stored value must be untouched by the read.
	if again, _ := g.LastAccessOf("s1"); !again.Equal(stale) {
		t.Fatalf("LastAccessOf mutated stored LastAccess: got %v, want %v", again, stale)
	}

	// The staleness comparison the reaper actually performs must now hold.
	threshold := time.Now().Add(-2 * time.Hour)
	if !got.Before(threshold) {
		t.Fatal("stale session did not compare as stale — reaper would skip it")
	}
}

// TestGetSessionStillRefreshes guards the other half of the contract: the playback
// path relies on GetSession keeping a session alive.
func TestGetSessionStillRefreshes(t *testing.T) {
	g := NewHLSGenerator(HLSConfig{})

	stale := time.Now().Add(-3 * time.Hour)
	g.sessions["s1"] = &HLSSession{SessionID: "s1", LastAccess: stale}

	if _, ok := g.GetSession("s1"); !ok {
		t.Fatal("GetSession: session not found")
	}

	got, _ := g.LastAccessOf("s1")
	if got.Equal(stale) {
		t.Fatal("GetSession no longer refreshes LastAccess — active sessions would be reaped mid-playback")
	}
}

// TestCleanupInactiveEvictsStaleSession drives the reaper end to end and asserts the
// stale session is gone while the fresh one survives.
func TestCleanupInactiveEvictsStaleSession(t *testing.T) {
	g := NewHLSGenerator(HLSConfig{})
	g.sessions["stale"] = &HLSSession{
		SessionID:  "stale",
		OutputDir:  t.TempDir(),
		LastAccess: time.Now().Add(-3 * time.Hour),
	}
	g.sessions["fresh"] = &HLSSession{
		SessionID:  "fresh",
		OutputDir:  t.TempDir(),
		LastAccess: time.Now(),
	}

	m := NewCleanupManager(CleanupConfig{
		InactivityTimeout: 2 * time.Hour,
		TempDir:           t.TempDir(),
	}, g)

	m.cleanupInactive()

	if _, ok := g.LastAccessOf("stale"); ok {
		t.Error("stale session survived the reaper")
	}
	if _, ok := g.LastAccessOf("fresh"); !ok {
		t.Error("fresh session was evicted")
	}
}

// TestSessionErrorReadsUnderLock covers the companion fix: callers must read a
// session's terminal error through the generator rather than through the pointer
// GetSession hands back after releasing the mutex.
func TestSessionErrorReadsUnderLock(t *testing.T) {
	g := NewHLSGenerator(HLSConfig{})
	g.sessions["s1"] = &HLSSession{SessionID: "s1"}

	if err, ok := g.SessionError("s1"); !ok || err != nil {
		t.Fatalf("SessionError on a healthy session: got (%v, %v), want (nil, true)", err, ok)
	}

	if _, ok := g.SessionError("missing"); ok {
		t.Error("SessionError reported ok for a session that does not exist")
	}
}

// The trickplay and embedded-subtitle caches live INSIDE TempDir, alongside session
// directories. Both cleanup paths used to treat them as orphaned sessions:
//
//   - cleanupOrphanedDirs deleted any directory with no matching session once it was older
//     than InactivityTimeout. A directory's mtime only bumps when a new child is created,
//     so a settled library's caches aged out and were deleted every couple of hours.
//   - cleanupAll did os.RemoveAll(TempDir) on every SIGTERM, so every package upgrade
//     wiped them wholesale.
//
// Rebuilding either is a full-file ffmpeg pass drawing on the same budget live playback
// competes for, so this was pure self-inflicted work on a NAS with no hardware encoder.

func TestOrphanSweepPreservesCaches(t *testing.T) {
	tmp := t.TempDir()
	g := NewHLSGenerator(HLSConfig{})
	m := NewCleanupManager(CleanupConfig{InactivityTimeout: time.Millisecond, TempDir: tmp}, g)

	// Two long-lived caches and one genuinely orphaned session dir, all stale.
	for _, name := range []string{"trickplay", "embedded_subs", "sess_orphaned"} {
		if err := os.MkdirAll(filepath.Join(tmp, name, "item1"), 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", name, err)
		}
	}
	time.Sleep(5 * time.Millisecond) // age everything past the timeout

	m.cleanupOrphanedDirs()

	for _, name := range []string{"trickplay", "embedded_subs"} {
		if _, err := os.Stat(filepath.Join(tmp, name)); err != nil {
			t.Errorf("%s cache was deleted by the orphan sweep: %v", name, err)
		}
	}
	if _, err := os.Stat(filepath.Join(tmp, "sess_orphaned")); err == nil {
		t.Error("a genuinely orphaned session directory should still be reclaimed")
	}
}

func TestShutdownPreservesCaches(t *testing.T) {
	tmp := t.TempDir()
	g := NewHLSGenerator(HLSConfig{})
	m := NewCleanupManager(CleanupConfig{InactivityTimeout: time.Hour, TempDir: tmp}, g)

	for _, name := range []string{"trickplay", "embedded_subs", "sess_live"} {
		if err := os.MkdirAll(filepath.Join(tmp, name, "item1"), 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", name, err)
		}
	}

	m.cleanupAll()

	for _, name := range []string{"trickplay", "embedded_subs"} {
		if _, err := os.Stat(filepath.Join(tmp, name)); err != nil {
			t.Errorf("%s cache was deleted on shutdown — every upgrade would rebuild it: %v", name, err)
		}
	}
	// Session scratch SHOULD go: it is unusable after a restart.
	if _, err := os.Stat(filepath.Join(tmp, "sess_live")); err == nil {
		t.Error("session scratch should be removed on shutdown")
	}
}
