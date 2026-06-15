package transcode

import (
	"context"
	"runtime"
	"time"
)

// FFmpegLimiter is a single, process-wide admission budget for ALL ffmpeg
// invocations: HLS transcode (live playback), trickplay sprite generation, and
// subtitle conversion passes.
//
// TASK-752: before this, there were TWO uncoordinated pools — HLS held a
// MaxConcurrent=3 slot accounting that only gated HLS sessions, while trickplay
// had its OWN size-2 semaphore and subtitle conversion was ungated entirely.
// On a 4-core / 3.8GB NAS with NO hardware encoder (software libx264 only), that
// let 5+ ffmpeg processes run at once. The kernel OOM/CPU-killed them ("signal:
// killed"), HLS playlist generation missed the client's 30s WaitForPlaylist
// window, and playback failed intermittently under load. A single shared budget
// is the fix: total ffmpeg concurrency can never exceed what the box can sustain,
// regardless of which subsystem is spawning the work.
type FFmpegLimiter struct {
	slots chan struct{}
}

// NewFFmpegLimiter creates a limiter with the given number of slots. A size <= 0
// is clamped to 1 so there is always at least one usable slot.
func NewFFmpegLimiter(size int) *FFmpegLimiter {
	if size < 1 {
		size = 1
	}
	return &FFmpegLimiter{slots: make(chan struct{}, size)}
}

// DefaultFFmpegConcurrency returns the auto-sized ffmpeg budget: half the logical
// CPUs, floored at 1. On the 4-core NAS this yields 2 — enough headroom for one
// live transcode plus a backgrounded trickplay pass without saturating all cores
// (libx264 is already given -threads per invocation on top of this).
func DefaultFFmpegConcurrency() int {
	n := runtime.NumCPU() / 2
	if n < 1 {
		n = 1
	}
	return n
}

// Acquire blocks for a slot, honouring ctx cancellation. Returns ctx.Err() if the
// caller's context is cancelled before a slot is free — this keeps a cancelled
// playback from deadlocking the goroutine while it waits behind a saturated budget.
func (l *FFmpegLimiter) Acquire(ctx context.Context) error {
	if l == nil {
		return nil
	}
	select {
	case l.slots <- struct{}{}:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// TryAcquire attempts to take a slot, waiting at most `timeout` for one to free up.
// It reports whether a slot was obtained. This is the trickplay-yield mechanism:
// trickplay is a background convenience, so it must NOT block indefinitely holding
// out for a slot — if the budget is saturated by live playback it backs off and the
// caller returns its normal "trickplay_unavailable" 404 (the client handles that
// gracefully). The invariant: live playback transcodes always eventually get a slot
// (they use Acquire and wait), trickplay yields (it uses TryAcquire and gives up).
func (l *FFmpegLimiter) TryAcquire(ctx context.Context, timeout time.Duration) bool {
	if l == nil {
		return true
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case l.slots <- struct{}{}:
		return true
	case <-timer.C:
		return false
	case <-ctx.Done():
		return false
	}
}

// Release returns a previously acquired slot to the budget. It must be paired with
// a successful Acquire/TryAcquire.
func (l *FFmpegLimiter) Release() {
	if l == nil {
		return
	}
	select {
	case <-l.slots:
	default:
		// Defensive: never block on an over-release.
	}
}
