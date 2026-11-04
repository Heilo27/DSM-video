package main

import (
	"context"
	"log"
	"net/http"
	"sync/atomic"
	"time"
)

// Non-loopback request counter (TASK-1082 P1-1).
//
// The packaged nginx is the only thing meant to talk to the backend, over loopback; that is
// why trustedRealIP honours X-Real-IP / X-Forwarded-For only from a loopback peer. A request
// whose TCP peer is NOT loopback reached the backend port directly, around nginx. The counter
// makes that visible: if it is ever non-zero the backend is exposed and its limiters are
// keyed on the real peer (forwarded headers are ignored for it). It counts only; no address
// is stored or logged.
type peerCounter struct {
	nonLoopback atomic.Int64
	since       time.Time
	lastLogged  atomic.Int64
}

func newPeerCounter(now time.Time) *peerCounter { return &peerCounter{since: now} }

// middleware counts a request when its raw TCP peer is not loopback. It must be registered
// BEFORE trustedRealIP, which rewrites RemoteAddr.
func (c *peerCounter) middleware(next http.Handler) http.Handler {
	if c == nil {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !peerIsLoopback(r.RemoteAddr) {
			c.nonLoopback.Add(1)
		}
		next.ServeHTTP(w, r)
	})
}

// snapshot is what /admin/status exposes.
func (c *peerCounter) snapshot() map[string]any {
	if c == nil {
		return map[string]any{"count": int64(0), "since": ""}
	}
	return map[string]any{
		"count": c.nonLoopback.Load(),
		"since": c.since.UTC().Format(time.RFC3339),
	}
}

// logDelta logs the requests counted since the previous call and returns that delta.
func (c *peerCounter) logDelta() int64 {
	total := c.nonLoopback.Load()
	delta := total - c.lastLogged.Swap(total)
	log.Printf("[security] non-loopback requests in the last 24h: %d (total since %s: %d)",
		delta, c.since.UTC().Format(time.RFC3339), total)
	return delta
}

// runDailyLog logs the counter once every 24 hours until ctx ends.
func (c *peerCounter) runDailyLog(ctx context.Context, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			c.logDelta()
		}
	}
}
