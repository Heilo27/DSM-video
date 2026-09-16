package transcode

import (
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

func TestSeekStormDoesNotLockOutPlayback(t *testing.T) {
	g := NewHLSGenerator(HLSConfig{MaxConcurrent: 3, TempDir: t.TempDir()})
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
	// This is the one test here that starts a REAL session, so it is the one that must stop
	// it. StartSession spawns ffmpeg writing segments into the generator's TempDir; without
	// this the test returns while that process is still writing and t.TempDir()'s RemoveAll
	// races it — an intermittent "TempDir RemoveAll cleanup: unlinkat ...: directory not
	// empty" that fails the package only under the load of a full `go test ./...` run.
	t.Cleanup(func() { _ = g.StopSession(sess.SessionID) })

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
