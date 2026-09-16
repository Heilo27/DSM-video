package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// The public image route is a deliberate tradeoff (Top Shelf cannot send a header), but
// being UNLIMITED was never part of that tradeoff. Item IDs are hex of an absolute path,
// so 200-vs-404 is a path oracle; enumerating with it needs volume, and a per-IP cap is
// what removes the practical attack while leaving artwork working.
//
// These tests pin the two things that make the limiter safe to ship: it must not fire for
// a real client's burst, and it must not share a counter with the login limiter in either
// direction.

func newRateLimitServer() *Server { return &Server{} }

func reqFrom(ip string) *http.Request {
	r := httptest.NewRequest("GET", "/api/v1/images/it_abc", nil)
	r.RemoteAddr = ip + ":51000"
	return r
}

func TestImageRateLimitAllowsARealHomeScreenBurst(t *testing.T) {
	s := newRateLimitServer()
	// Four rails of 16, loaded twice over (navigating away and back), from one device.
	const realisticBurst = 4 * 16 * 2
	for i := 0; i < realisticBurst; i++ {
		if s.rateLimitExceeded(reqFrom("10.0.0.5"), rateLimitBucketImage, imageRateLimitMax, imageRateLimitWindow) {
			t.Fatalf("limiter fired after %d poster loads — a real home screen would break", i+1)
		}
	}
}

func TestImageRateLimitStopsAnEnumerationSweep(t *testing.T) {
	s := newRateLimitServer()
	var blocked bool
	for i := 0; i < imageRateLimitMax+50; i++ {
		if s.rateLimitExceeded(reqFrom("10.0.0.6"), rateLimitBucketImage, imageRateLimitMax, imageRateLimitWindow) {
			blocked = true
			break
		}
	}
	if !blocked {
		t.Fatalf("limiter never fired within %d requests — the route is still an unthrottled oracle",
			imageRateLimitMax+50)
	}
}

// Two IPs must not share a budget: one NAT'd household enumerating must not lock out
// another user, and more importantly one user's posters must not be blocked by someone else.
func TestRateLimitIsPerIP(t *testing.T) {
	s := newRateLimitServer()
	for i := 0; i < imageRateLimitMax+10; i++ {
		s.rateLimitExceeded(reqFrom("10.0.0.7"), rateLimitBucketImage, imageRateLimitMax, imageRateLimitWindow)
	}
	if s.rateLimitExceeded(reqFrom("10.0.0.8"), rateLimitBucketImage, imageRateLimitMax, imageRateLimitWindow) {
		t.Error("a different IP was blocked by the first IP's usage")
	}
}

// The buckets must be independent IN BOTH DIRECTIONS. Sharing one counter would mean either
// that loading artwork locks you out of logging in, or that the login limiter's tiny budget
// (10/min) throttles posters — and a single shared map key is an easy way to get this wrong.
func TestImageAndAuthBudgetsDoNotShareACounter(t *testing.T) {
	t.Run("posters do not consume the login budget", func(t *testing.T) {
		s := newRateLimitServer()
		for i := 0; i < imageRateLimitMax+10; i++ {
			s.rateLimitExceeded(reqFrom("10.0.0.9"), rateLimitBucketImage, imageRateLimitMax, imageRateLimitWindow)
		}
		if s.authRateLimitExceeded(reqFrom("10.0.0.9")) {
			t.Error("loading artwork exhausted the login budget for the same IP")
		}
	})

	t.Run("login attempts do not throttle posters", func(t *testing.T) {
		s := newRateLimitServer()
		for i := 0; i < 50; i++ {
			s.authRateLimitExceeded(reqFrom("10.0.0.10"))
		}
		if s.rateLimitExceeded(reqFrom("10.0.0.10"), rateLimitBucketImage, imageRateLimitMax, imageRateLimitWindow) {
			t.Error("failed logins blocked artwork for the same IP")
		}
	})
}

// The login limiter's own budget must be unchanged by the refactor that generalised it.
func TestAuthRateLimitStillAllowsTenThenBlocks(t *testing.T) {
	s := newRateLimitServer()
	for i := 1; i <= 10; i++ {
		if s.authRateLimitExceeded(reqFrom("10.0.0.11")) {
			t.Fatalf("login limiter fired on attempt %d, want it to allow 10", i)
		}
	}
	if !s.authRateLimitExceeded(reqFrom("10.0.0.11")) {
		t.Error("login limiter allowed an 11th attempt")
	}
}

// A window that has elapsed must reset, or a long-lived client is permanently throttled.
func TestRateLimitWindowResets(t *testing.T) {
	s := newRateLimitServer()
	const tiny = 20 * time.Millisecond
	for i := 0; i < 3; i++ {
		s.rateLimitExceeded(reqFrom("10.0.0.12"), rateLimitBucketImage, 2, tiny)
	}
	if !s.rateLimitExceeded(reqFrom("10.0.0.12"), rateLimitBucketImage, 2, tiny) {
		t.Fatal("expected to be over the tiny budget before the window elapses")
	}
	time.Sleep(tiny * 3)
	if s.rateLimitExceeded(reqFrom("10.0.0.12"), rateLimitBucketImage, 2, tiny) {
		t.Error("still throttled after the window elapsed — the reset did not happen")
	}
}

// IPv6 RemoteAddr must key correctly. Truncating at the last colon (strings.LastIndex)
// would mangle the address into a different key per port and defeat the limiter entirely.
func TestRateLimitKeysIPv6Correctly(t *testing.T) {
	s := newRateLimitServer()
	mk := func(port string) *http.Request {
		r := httptest.NewRequest("GET", "/api/v1/images/it_abc", nil)
		r.RemoteAddr = "[2001:db8::1]:" + port
		return r
	}
	for i := 0; i < 3; i++ {
		s.rateLimitExceeded(mk("51000"), rateLimitBucketImage, 2, time.Minute)
	}
	// Same host, different source port: must hit the SAME counter.
	if !s.rateLimitExceeded(mk("51999"), rateLimitBucketImage, 2, time.Minute) {
		t.Error("an IPv6 client evaded the limiter by changing source port — key is wrong")
	}
}

// The middleware must actually answer 429 with Retry-After, not just count.
func TestImageRateLimitMiddlewareReturns429(t *testing.T) {
	s := newRateLimitServer()
	var served int
	h := s.imageRateLimit(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		served++
		w.WriteHeader(http.StatusOK)
	}))

	for i := 0; i < imageRateLimitMax; i++ {
		h.ServeHTTP(httptest.NewRecorder(), reqFrom("10.0.0.13"))
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, reqFrom("10.0.0.13"))

	if rec.Code != http.StatusTooManyRequests {
		t.Errorf("status = %d, want 429", rec.Code)
	}
	if rec.Header().Get("Retry-After") == "" {
		t.Error("429 carries no Retry-After header")
	}
	if served > imageRateLimitMax {
		t.Errorf("handler ran %d times, want at most %d", served, imageRateLimitMax)
	}
}
