package normalize

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Cancelling a conversion must leave NO running ffmpeg and NO partial output file.
//
// This is the second half of the shutdown fix. The first half is that the normalize worker
// now runs on a cancellable context at all: it previously ran on context.Background(), so
// SIGTERM never reached it and DSM's SIGKILL 10 seconds later orphaned whatever ffmpeg was
// mid-conversion, leaving a ".<stem>.converting.mp4" nothing would finish or clean up.
//
// Worth recording precisely, because the obvious theory is wrong: `nice` EXECs into ffmpeg
// rather than forking (verified with ps), so ffmpeg is the DIRECT child and
// exec.CommandContext's default kill already reaches it. The explicit process-group kill in
// Convert is defence in depth, not the fix. The fix is that cancellation happens.
//
// So this test asserts the OUTCOME — nothing left running, nothing left on disk — rather
// than the mechanism, and it would still hold if the wrapper changed.

func ffmpegOrSkip(t *testing.T) string {
	t.Helper()
	path, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg not installed")
	}
	return path
}

func countFFmpegChildren(t *testing.T, marker string) int {
	t.Helper()
	out, err := exec.Command("ps", "-eo", "command").Output()
	if err != nil {
		t.Fatalf("ps: %v", err)
	}
	n := 0
	for _, line := range strings.Split(string(out), "\n") {
		if strings.Contains(line, marker) && strings.Contains(line, "ffmpeg") {
			n++
		}
	}
	return n
}

func TestCancelLeavesNoRunningFFmpegOrPartialFile(t *testing.T) {
	ffmpeg := ffmpegOrSkip(t)
	if _, err := exec.LookPath("nice"); err != nil {
		t.Skip("nice not available")
	}

	dir := t.TempDir()
	// A long synthetic source, so the conversion is still running when we cancel.
	src := filepath.Join(dir, "cancel-probe-source.mkv")
	gen := exec.Command(ffmpeg, "-y", "-v", "error",
		"-f", "lavfi", "-i", "testsrc=size=640x360:rate=30:duration=90",
		"-c:v", "libx264", "-preset", "ultrafast", src)
	if err := gen.Run(); err != nil {
		t.Skipf("could not build a fixture: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		// ActionEncode is deliberately the slow path, so it is certainly mid-run.
		_, _ = Convert(ctx, ffmpeg, "", src, ActionEncode, 1080)
	}()

	// Wait for ffmpeg to actually be running on our fixture.
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		if countFFmpegChildren(t, "cancel-probe-source") > 0 {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if countFFmpegChildren(t, "cancel-probe-source") == 0 {
		cancel()
		<-done
		t.Skip("ffmpeg never started for this fixture; nothing to assert")
	}

	cancel()

	// The grandchild must die. Before the fix it survived indefinitely.
	gone := false
	deadline = time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if countFFmpegChildren(t, "cancel-probe-source") == 0 {
			gone = true
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	<-done

	if !gone {
		// Don't leave a real orphan behind if the assertion fails.
		_ = exec.Command("pkill", "-f", "cancel-probe-source").Run()
		t.Fatal("ffmpeg survived cancellation — on DSM this is the process that outlives SIGTERM " +
			"and keeps writing a partial .converting.mp4")
	}

	// And the half-written temp file must not be left behind.
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".converting.mp4") {
			t.Errorf("a partial conversion file was left behind: %s", e.Name())
		}
	}
}

// WaitForIdle must be bounded and must never block shutdown on a nil worker.
func TestWaitForIdleIsBoundedAndNilSafe(t *testing.T) {
	var w *NormalizeWorker
	w.WaitForIdle(time.Second) // must not panic

	real := &NormalizeWorker{converting: map[string]struct{}{}}
	start := time.Now()
	real.WaitForIdle(time.Second)
	if elapsed := time.Since(start); elapsed > 200*time.Millisecond {
		t.Errorf("an idle worker should return immediately, took %v", elapsed)
	}

	// A stuck conversion must not hold shutdown open past the timeout.
	real.converting["stuck"] = struct{}{}
	start = time.Now()
	real.WaitForIdle(300 * time.Millisecond)
	elapsed := time.Since(start)
	if elapsed < 250*time.Millisecond {
		t.Errorf("returned before the timeout: %v", elapsed)
	}
	if elapsed > 2*time.Second {
		t.Errorf("exceeded its timeout by too much: %v", elapsed)
	}
}
