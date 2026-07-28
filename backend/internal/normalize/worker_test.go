package normalize

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TestConvertGuards — Convert must reject obviously-invalid invocations without
// touching the filesystem: no ffmpeg path, and ActionSkip.
func TestConvertGuards(t *testing.T) {
	if _, err := Convert(context.Background(), "", "ffprobe", "/tmp/x.mkv", ActionEncode, 720); err == nil {
		t.Error("Convert with empty ffmpeg path should error")
	}
	if _, err := Convert(context.Background(), "ffmpeg", "ffprobe", "/tmp/x.mkv", ActionSkip, 720); err == nil {
		t.Error("Convert with ActionSkip should error")
	}
}

// TestTargetOutputPath — output is "<stem>.mp4" in the source directory regardless of
// the source extension.
func TestTargetOutputPath(t *testing.T) {
	cases := map[string]string{
		"/v/Movies/A Film (2020).mkv": "/v/Movies/A Film (2020).mp4",
		"/v/TV/Show/s01e01.avi":       "/v/TV/Show/s01e01.mp4",
		"/v/Movies/already.mp4":       "/v/Movies/already.mp4",
		"/v/clip.with.dots.webm":      "/v/clip.with.dots.mp4",
	}
	for src, want := range cases {
		if got := TargetOutputPath(src); got != want {
			t.Errorf("TargetOutputPath(%q) = %q, want %q", src, got, want)
		}
	}
}

// TestBackupPathPreservesRelative — the backup destination preserves the path relative
// to the media root; a src outside the root falls back to abs-path-minus-leading-sep.
func TestBackupPath(t *testing.T) {
	w := &NormalizeWorker{backupDir: "/v/_dsvideo_originals"}

	got := w.backupPath("/v/Movies/Dir/file.mkv", "/v/Movies")
	if want := "/v/_dsvideo_originals/Dir/file.mkv"; got != want {
		t.Errorf("backupPath under root = %q, want %q", got, want)
	}

	// src not under the given root → fall back to stripping the leading separator.
	got = w.backupPath("/other/place/file.mkv", "/v/Movies")
	if want := "/v/_dsvideo_originals/other/place/file.mkv"; got != want {
		t.Errorf("backupPath outside root = %q, want %q", got, want)
	}
}

// TestMoveFile — same-volume move works and the source is gone afterward.
func TestMoveFile(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "src.txt")
	dst := filepath.Join(dir, "sub", "dst.txt")
	if err := os.WriteFile(src, []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := moveFile(src, dst); err != nil {
		t.Fatalf("moveFile: %v", err)
	}
	if _, err := os.Stat(src); !os.IsNotExist(err) {
		t.Error("source should be gone after move")
	}
	b, err := os.ReadFile(dst)
	if err != nil || string(b) != "hello" {
		t.Errorf("dst content = %q (err %v), want \"hello\"", b, err)
	}
}

// TestEnqueueDedupAndConvertingSet — Enqueue dedups by itemID and the converting set
// is consulted by IsConverting. We exercise the maps directly since the goroutine
// loop needs ffmpeg to make real progress.
func TestEnqueueDedupAndConvertingSet(t *testing.T) {
	w := NewNormalizeWorker("ffmpeg", "ffprobe", t.TempDir(), 720, nil, func() bool { return true }, nil)

	w.Enqueue("itemA", "/v/a.mkv", "/v")
	w.Enqueue("itemA", "/v/a.mkv", "/v") // duplicate — must not enqueue twice
	if len(w.queue) != 1 {
		t.Errorf("queue len = %d, want 1 (dedup failed)", len(w.queue))
	}

	if w.IsConverting("itemA") {
		t.Error("itemA should not be in converting set yet")
	}
	w.mu.Lock()
	w.converting["itemA"] = struct{}{}
	w.mu.Unlock()
	if !w.IsConverting("itemA") {
		t.Error("IsConverting should report true once item is in the set")
	}
}

// TestPermaFailedStopsRequeue — a deterministic failure (unreadable file, or a target
// name already taken by an unrelated file) must retire the item instead of being
// re-enqueued by every library scan. Production regression: three unreadable DS9
// episodes and one .AVI whose .mp4 twin already existed were retried on every scan for
// hours, one of them burning a full re-encode each time before the post-convert guard
// caught it.
func TestPermaFailedStopsRequeue(t *testing.T) {
	w := NewNormalizeWorker("ffmpeg", "ffprobe", t.TempDir(), 1080, nil, func() bool { return true }, nil)

	// First enqueue is accepted.
	w.Enqueue("bad1", "/v/corrupt.mkv", "/v")
	if len(w.queue) != 1 {
		t.Fatalf("queue len = %d, want 1", len(w.queue))
	}
	// Drain it, then retire it the way process() would on a probe failure.
	<-w.queue
	w.mu.Lock()
	delete(w.queued, "bad1")
	w.mu.Unlock()
	w.markPermaFailed("bad1", "ffprobe could not read the file")

	// A later scan re-enqueues — must be ignored now.
	w.Enqueue("bad1", "/v/corrupt.mkv", "/v")
	if len(w.queue) != 0 {
		t.Errorf("queue len = %d, want 0 — retired item was re-enqueued", len(w.queue))
	}

	// An unrelated item is unaffected.
	w.Enqueue("good1", "/v/fine.mkv", "/v")
	if len(w.queue) != 1 {
		t.Errorf("queue len = %d, want 1 — retirement leaked to an unrelated item", len(w.queue))
	}

	if got := w.PermaFailed(); got["bad1"] == "" {
		t.Error("PermaFailed() should report a reason for bad1")
	} else if _, leaked := got["good1"]; leaked {
		t.Error("PermaFailed() must not contain healthy items")
	}

	// Snapshot must be a copy — mutating it can't corrupt worker state.
	w.PermaFailed()["bad1"] = "tampered"
	if w.PermaFailed()["bad1"] == "tampered" {
		t.Error("PermaFailed() returned a live map, not a snapshot")
	}
}

// TestWouldClobber — Worf P1-4: a same-path target (.mp4 remux of an .mp4) is never a
// clobber; a different-path target (.mkv→.mp4) is a clobber ONLY when that .mp4 already
// exists on disk as a separate file.
func TestWouldClobber(t *testing.T) {
	dir := t.TempDir()
	mkv := filepath.Join(dir, "Movie.mkv")
	mp4 := filepath.Join(dir, "Movie.mp4")

	// Same path → never a clobber, even if it exists.
	if err := os.WriteFile(mp4, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if wouldClobber(mp4, mp4) {
		t.Error("same-path target must not be treated as a clobber")
	}

	// Different path, target exists → clobber (abort).
	if !wouldClobber(mkv, mp4) {
		t.Error("different-path target that already exists must be a clobber")
	}

	// Different path, target absent → safe.
	if err := os.Remove(mp4); err != nil {
		t.Fatal(err)
	}
	if wouldClobber(mkv, mp4) {
		t.Error("different-path target that does not exist must be safe")
	}
}

// TestReapBackups — files older than the retention window are deleted; fresh ones stay.
func TestReapBackups(t *testing.T) {
	backup := t.TempDir()
	w := &NormalizeWorker{backupDir: backup}

	old := filepath.Join(backup, "sub", "old.mkv")
	fresh := filepath.Join(backup, "sub", "fresh.mkv")
	if err := os.MkdirAll(filepath.Dir(old), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{old, fresh} {
		if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// Backdate "old" 8 days; leave "fresh" at now.
	eightDaysAgo := time.Now().Add(-8 * 24 * time.Hour)
	if err := os.Chtimes(old, eightDaysAgo, eightDaysAgo); err != nil {
		t.Fatal(err)
	}

	w.reapBackups(7)

	if _, err := os.Stat(old); !os.IsNotExist(err) {
		t.Error("old backup should have been reaped")
	}
	if _, err := os.Stat(fresh); err != nil {
		t.Error("fresh backup should have survived")
	}
}
