package transcode

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// TASK-752: the FFmpegLimiter is a process-wide concurrency primitive guarding all
// ffmpeg launches. These tests lock in its invariants — run with `go test -race`.

// TestLimiterNeverExceedsBudget hammers Acquire/Release from many goroutines and
// asserts the number of concurrently-held slots never exceeds the budget.
func TestLimiterNeverExceedsBudget(t *testing.T) {
	const budget = 2
	l := NewFFmpegLimiter(budget)
	ctx := context.Background()

	var inFlight int64
	var maxSeen int64
	var wg sync.WaitGroup

	for i := 0; i < 200; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := l.Acquire(ctx); err != nil {
				t.Errorf("Acquire: %v", err)
				return
			}
			n := atomic.AddInt64(&inFlight, 1)
			for {
				m := atomic.LoadInt64(&maxSeen)
				if n <= m || atomic.CompareAndSwapInt64(&maxSeen, m, n) {
					break
				}
			}
			time.Sleep(time.Millisecond)
			atomic.AddInt64(&inFlight, -1)
			l.Release()
		}()
	}
	wg.Wait()

	if maxSeen > budget {
		t.Fatalf("budget exceeded: saw %d concurrent, budget %d", maxSeen, budget)
	}
}

// TestAcquireHonoursCancel verifies a blocked Acquire unblocks with ctx.Err() when
// its context is cancelled — the path StopSession relies on to free a slot held by
// a transcode that's waiting behind a saturated budget.
func TestAcquireHonoursCancel(t *testing.T) {
	l := NewFFmpegLimiter(1)
	if err := l.Acquire(context.Background()); err != nil {
		t.Fatalf("first acquire: %v", err)
	}
	// Budget is now exhausted. A second acquire must block until cancelled.
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- l.Acquire(ctx) }()

	select {
	case err := <-done:
		t.Fatalf("acquire returned %v before cancel — should have blocked", err)
	case <-time.After(50 * time.Millisecond):
	}

	cancel()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("acquire returned nil after cancel — should be ctx.Err()")
		}
	case <-time.After(time.Second):
		t.Fatal("acquire did not unblock after cancel")
	}
	l.Release()
}

// TestTryAcquireYields verifies trickplay's bounded-wait acquire backs off when the
// budget is saturated, rather than blocking — the starvation invariant.
func TestTryAcquireYields(t *testing.T) {
	l := NewFFmpegLimiter(1)
	if err := l.Acquire(context.Background()); err != nil {
		t.Fatalf("acquire: %v", err)
	}
	start := time.Now()
	got := l.TryAcquire(context.Background(), 30*time.Millisecond)
	elapsed := time.Since(start)
	if got {
		t.Fatal("TryAcquire succeeded against a saturated budget")
	}
	if elapsed < 30*time.Millisecond {
		t.Fatalf("TryAcquire returned after %v — should wait the full timeout", elapsed)
	}
	l.Release()
	// Now a slot is free; TryAcquire should succeed promptly.
	if !l.TryAcquire(context.Background(), time.Second) {
		t.Fatal("TryAcquire failed despite a free slot")
	}
	l.Release()
}

// TestNilLimiterNoOps confirms an uninjected (nil) limiter no-ops safely: Acquire
// succeeds, TryAcquire reports success, Release does nothing.
func TestNilLimiterNoOps(t *testing.T) {
	var l *FFmpegLimiter
	if err := l.Acquire(context.Background()); err != nil {
		t.Fatalf("nil Acquire returned %v", err)
	}
	if !l.TryAcquire(context.Background(), time.Millisecond) {
		t.Fatal("nil TryAcquire returned false")
	}
	l.Release() // must not panic
}

// TestReleaseNeverBlocks confirms an over-release is a safe no-op (defensive path).
func TestReleaseNeverBlocks(t *testing.T) {
	l := NewFFmpegLimiter(1)
	done := make(chan struct{})
	go func() {
		l.Release() // nothing acquired — must not block
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("over-release blocked")
	}
}

// TestDefaultConcurrencyFloor confirms the auto-size never returns < 1.
func TestDefaultConcurrencyFloor(t *testing.T) {
	if n := DefaultFFmpegConcurrency(); n < 1 {
		t.Fatalf("DefaultFFmpegConcurrency = %d, want >= 1", n)
	}
	if n := NewFFmpegLimiter(0); cap(n.slots) != 1 {
		t.Fatalf("NewFFmpegLimiter(0) cap = %d, want 1", cap(n.slots))
	}
}
