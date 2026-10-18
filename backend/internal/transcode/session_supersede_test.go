package transcode

import (
	"os"
	"testing"
	"time"
)

// THE SEEK STORM.
//
// Every /playback request mints a fresh random session id, so a viewer scrubbing a
// transcoded title issued a brand-new ffmpeg per seek. Three drags in a few seconds filled
// MaxConcurrent (3 on this hardware), and the eviction path refuses to evict anything
// touched within the last 20 seconds — so the FOURTH seek hard-failed with "maximum
// concurrent transcodes reached" and playback stayed locked out for the rest of the grace
// window. Locked out by the user's own abandoned sessions, while scrubbing one film.
//
// Reproduced before the fix: with three sessions aged 5s/3s/0s, the fourth call returned
// that error. These tests pin the fix.

const testOwner = "user1|it_film"

// stopSessionsOnCleanup stops every session g still holds when the test ends. Each test in
// this file that calls StartSession starts a REAL transcode: a goroutine that runs ffmpeg
// (wherever one is installed) against the fake source, and on its failure runs the
// copy-failure retry, which removes and re-creates the session's OutputDir under the
// generator's TempDir and opens a new ffmpeg.log there. A test that returned with that
// goroutine alive raced t.TempDir()'s RemoveAll: "TempDir RemoveAll cleanup: unlinkat
// .../new: directory not empty", about 1 run in 20 (TASK-941). StopSession now returns only
// after the goroutine has exited, so stopping here leaves nothing writing.
//
// Call it AFTER NewHLSGenerator(...t.TempDir()...): cleanups run last-registered-first, so
// the sessions stop before their TempDir is removed.
func stopSessionsOnCleanup(t *testing.T, g *HLSGenerator) {
	t.Helper()
	t.Cleanup(func() {
		for _, id := range g.AllSessions() {
			if err := g.StopSession(id); err != nil {
				t.Errorf("StopSession(%s): %v", id, err)
			}
		}
	})
}

func TestSeekStormDoesNotLockOutPlayback(t *testing.T) {
	g := NewHLSGenerator(HLSConfig{MaxConcurrent: 3, TempDir: t.TempDir()})
	stopSessionsOnCleanup(t, g)
	now := time.Now()

	// A scrub burst: three sessions for the SAME viewer and title, all recent enough that
	// the 20s idle grace would refuse to evict any of them.
	for i, id := range []string{"a", "b", "c"} {
		g.sessions[id] = &HLSSession{
			SessionID:  id,
			OwnerKey:   testOwner,
			OutputDir:  t.TempDir(),
			LastAccess: now.Add(-time.Duration(5-i*2) * time.Second),
		}
	}
	g.active = 3

	// The next seek must be admitted, because it supersedes the same viewer's own work.
	sess, err := g.StartSession(nil, "d", "/tmp/film.mkv", RemuxOnly, 0, nil, 0, testOwner)
	if err != nil {
		t.Fatalf("a 4th rapid seek on the same title must not be refused: %v", err)
	}
	if sess == nil {
		t.Fatal("expected a session")
	}

	// The three superseded sessions must be gone — they were transcoding positions nobody
	// will ever watch.
	for _, id := range []string{"a", "b", "c"} {
		if _, still := g.sessions[id]; still {
			t.Errorf("session %s should have been superseded", id)
		}
	}
	if g.active > g.config.MaxConcurrent {
		t.Errorf("g.active = %d exceeds MaxConcurrent %d", g.active, g.config.MaxConcurrent)
	}
}

// Superseding must be scoped to the SAME viewer and title. A second person watching
// something else is genuine contention and must not be cancelled.
func TestSupersedeDoesNotTouchOtherViewers(t *testing.T) {
	g := NewHLSGenerator(HLSConfig{MaxConcurrent: 3, TempDir: t.TempDir()})
	stopSessionsOnCleanup(t, g)
	g.sessions["other"] = &HLSSession{
		SessionID:  "other",
		OwnerKey:   "user2|it_other",
		OutputDir:  t.TempDir(),
		LastAccess: time.Now(),
	}
	g.active = 1

	if _, err := g.StartSession(nil, "mine", "/tmp/film.mkv", RemuxOnly, 0, nil, 0, testOwner); err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	if _, still := g.sessions["other"]; !still {
		t.Fatal("another viewer's session must never be superseded — that is real contention")
	}
}

// An empty owner key must supersede nothing, so an unkeyed caller can never cancel
// sessions wholesale.
func TestEmptyOwnerKeySupersedesNothing(t *testing.T) {
	g := NewHLSGenerator(HLSConfig{MaxConcurrent: 3, TempDir: t.TempDir()})
	stopSessionsOnCleanup(t, g)
	g.sessions["a"] = &HLSSession{SessionID: "a", OwnerKey: "", OutputDir: t.TempDir(), LastAccess: time.Now()}
	g.sessions["b"] = &HLSSession{SessionID: "b", OwnerKey: testOwner, OutputDir: t.TempDir(), LastAccess: time.Now()}
	g.active = 2

	if _, err := g.StartSession(nil, "c", "/tmp/x.mkv", RemuxOnly, 0, nil, 0, ""); err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	for _, id := range []string{"a", "b"} {
		if _, still := g.sessions[id]; !still {
			t.Errorf("session %s must survive an unkeyed request", id)
		}
	}
}

// A COMPLETED transcode decrements g.active but its map entry — and its OutputDir, holding
// every fMP4 segment of the film — stayed until a reaper ran. On this hardware a transcode
// finishes well before the viewer does (~5x realtime), so the normal case was a finished
// session sitting on roughly a gigabyte of segments for up to two hours.
func TestCompletedSessionsAreReclaimed(t *testing.T) {
	g := NewHLSGenerator(HLSConfig{MaxConcurrent: 3, TempDir: t.TempDir()})
	stopSessionsOnCleanup(t, g)
	old := time.Now().Add(-10 * time.Minute)
	fresh := time.Now()

	g.sessions["done_old"] = &HLSSession{
		SessionID: "done_old", OutputDir: t.TempDir(),
		LastAccess: old, CompletedAt: &old,
	}
	// Just finished — a client may still be pulling its last segments.
	g.sessions["done_now"] = &HLSSession{
		SessionID: "done_now", OutputDir: t.TempDir(),
		LastAccess: fresh, CompletedAt: &fresh,
	}
	g.active = 0

	if _, err := g.StartSession(nil, "new", "/tmp/x.mkv", RemuxOnly, 0, nil, 0, testOwner); err != nil {
		t.Fatalf("StartSession: %v", err)
	}

	if _, still := g.sessions["done_old"]; still {
		t.Error("a long-finished session should have been reclaimed")
	}
	if _, still := g.sessions["done_now"]; !still {
		t.Error("a just-finished session must survive its grace window — a client may still be fetching segments")
	}
}

// Eviction under pressure must choose a LIVE session. A completed one frees disk but no
// slot (g.active was already decremented when its transcode finished), so picking one
// would spend the single eviction attempt and still fail the re-check.
func TestEvictionPrefersLiveSessionsOverCompletedOnes(t *testing.T) {
	g := NewHLSGenerator(HLSConfig{MaxConcurrent: 1, TempDir: t.TempDir()})
	stopSessionsOnCleanup(t, g)
	ancient := time.Now().Add(-time.Hour)

	// Completed and very idle — the most tempting victim by LastAccess alone, but useless.
	g.sessions["completed"] = &HLSSession{
		SessionID: "completed", OwnerKey: "user9|other",
		OutputDir: t.TempDir(), LastAccess: ancient, CompletedAt: &ancient,
	}
	// Live, idle past the grace window: the one that actually holds the slot.
	g.sessions["live"] = &HLSSession{
		SessionID: "live", OwnerKey: "user9|other",
		OutputDir: t.TempDir(), LastAccess: ancient,
	}
	g.active = 1

	if _, err := g.StartSession(nil, "new", "/tmp/x.mkv", RemuxOnly, 0, nil, 0, testOwner); err != nil {
		t.Fatalf("expected admission after evicting the LIVE session, got: %v", err)
	}
	if _, still := g.sessions["live"]; still {
		t.Error("the live session held the slot and should have been evicted")
	}
}

// StopSession's contract: when it returns, the session's transcode goroutine has exited and
// its OutputDir is gone for good. It used to return as soon as it had signalled ffmpeg and
// removed the directory, while the goroutine could still re-create the directory in its
// copy-failure retry and open a new ffmpeg.log in it (TASK-941).
func TestStopSessionWaitsForTranscodeToExit(t *testing.T) {
	g := NewHLSGenerator(HLSConfig{MaxConcurrent: 1, TempDir: t.TempDir()})
	stopSessionsOnCleanup(t, g)
	sess, err := g.StartSession(nil, "s", "/tmp/x.mkv", RemuxOnly, 0, nil, 0, "")
	if err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	if err := g.StopSession("s"); err != nil {
		t.Fatalf("StopSession: %v", err)
	}
	select {
	case <-sess.done:
	default:
		t.Fatal("StopSession returned while the session's transcode goroutine was still running")
	}
	if _, err := os.Stat(sess.OutputDir); !os.IsNotExist(err) {
		t.Fatalf("OutputDir %s still exists after StopSession (stat err %v)", sess.OutputDir, err)
	}
}
