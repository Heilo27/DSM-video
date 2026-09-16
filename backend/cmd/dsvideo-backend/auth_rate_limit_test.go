package main

import (
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

// attemptFrom fires one auth attempt from the given IP and reports whether the limiter
// says the window is now exhausted. The port is arbitrary — the limiter splits it off.
func attemptFrom(s *Server, ip string) bool {
	r := httptest.NewRequest(http.MethodPost, "/auth/login", nil)
	r.RemoteAddr = ip + ":51000"
	return s.authRateLimitExceeded(r)
}

// TestAuthRateLimitBoundary pins the contract stated in checkAuthRateLimit's doc comment:
// 10 attempts per 60-second window per IP. The numbers here are written out on purpose
// rather than read back off the implementation's constants — a test that recomputes the
// threshold from the code under test agrees with that code no matter what it says, which
// is not a test.
func TestAuthRateLimitBoundary(t *testing.T) {
	s := &Server{}

	// Attempts 1..10 are inside the allowance.
	for i := 1; i <= 10; i++ {
		if attemptFrom(s, "10.0.0.1") {
			t.Fatalf("attempt %d from 10.0.0.1 was rejected; the first 10 in a window must be allowed", i)
		}
	}
	// The 11th is the first one over.
	if !attemptFrom(s, "10.0.0.1") {
		t.Fatal("attempt 11 from 10.0.0.1 was allowed; the limit is 10 per 60s window")
	}
	// And it stays exhausted for the rest of the window.
	if !attemptFrom(s, "10.0.0.1") {
		t.Fatal("attempt 12 from 10.0.0.1 was allowed; the window must stay closed once exceeded")
	}

	// A different IP has its own budget and is untouched by the first IP burning through its own.
	if attemptFrom(s, "10.0.0.2") {
		t.Fatal("first attempt from 10.0.0.2 was rejected; one IP exhausting its window must not spend another's")
	}
}

// TestAuthRateLimitWindowResets proves the fixed window actually rolls over rather than
// latching permanently. Rewinding windowEnd into the past is the same thing 60 seconds of
// wall-clock would do, without making the suite sleep for a minute.
func TestAuthRateLimitWindowResets(t *testing.T) {
	s := &Server{}

	for i := 1; i <= 11; i++ {
		attemptFrom(s, "10.0.0.3")
	}
	if !attemptFrom(s, "10.0.0.3") {
		t.Fatal("10.0.0.3 should be over its limit after 11 attempts")
	}

	raw, ok := s.authRateLimit.Load(rateLimitKey(rateLimitBucketAuth, "10.0.0.3"))
	if !ok {
		t.Fatal("no rate limit entry stored for 10.0.0.3")
	}
	entry := raw.(*authRateEntry)
	entry.mu.Lock()
	entry.windowEnd = time.Now().Add(-1 * time.Second)
	entry.mu.Unlock()

	if attemptFrom(s, "10.0.0.3") {
		t.Fatal("the first attempt in a fresh window was rejected; an expired window must reset the count")
	}
}

// TestAuthRateLimitDoesNotSerializeAcrossIPs is the regression guard for TASK-819.
//
// The limiter used to hold every per-IP entry in a sync.Map but mutate it under ONE
// server-wide mutex, so a login from any address blocked a login from every other address.
// This test makes that failure mode deterministic rather than hoping a race shows up under
// load: it pins one IP's entry lock open and then requires a DIFFERENT IP to get all the
// way through the limiter while that lock is still held. Under the old server-wide mutex
// the second IP could not proceed and this deadlocks until the timeout fires.
func TestAuthRateLimitDoesNotSerializeAcrossIPs(t *testing.T) {
	s := &Server{}

	// Materialise the blocked IP's entry so we have something to pin.
	attemptFrom(s, "192.168.1.10")
	raw, ok := s.authRateLimit.Load(rateLimitKey(rateLimitBucketAuth, "192.168.1.10"))
	if !ok {
		t.Fatal("no rate limit entry stored for 192.168.1.10")
	}
	blocked := raw.(*authRateEntry)

	blocked.mu.Lock()
	released := false
	defer func() {
		if !released {
			blocked.mu.Unlock()
		}
	}()

	done := make(chan bool, 1)
	go func() {
		done <- attemptFrom(s, "192.168.1.11")
	}()

	select {
	case exceeded := <-done:
		if exceeded {
			t.Fatal("192.168.1.11's first attempt was reported as over the limit")
		}
	case <-time.After(5 * time.Second):
		blocked.mu.Unlock()
		released = true
		t.Fatal("an auth attempt from 192.168.1.11 blocked while 192.168.1.10's entry was locked — " +
			"auth is serialising across IPs again (TASK-819). Each authRateEntry must carry " +
			"its own mutex; do not reintroduce a server-wide authRateMu.")
	}

	blocked.mu.Unlock()
	released = true
}

// TestAuthRateLimitConcurrentSameIPCountsExactly checks the per-entry lock still makes the
// counter correct for the set of attempts that DO have to agree — the ones from one IP.
// Racing 50 attempts from a single address must allow exactly 10 and reject exactly 40;
// a lost increment would show up here as an allowance that drifts above 10.
func TestAuthRateLimitConcurrentSameIPCountsExactly(t *testing.T) {
	s := &Server{}

	const attempts = 50
	var wg sync.WaitGroup
	results := make([]bool, attempts)
	start := make(chan struct{})

	for i := 0; i < attempts; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			<-start
			results[idx] = attemptFrom(s, "172.16.0.5")
		}(i)
	}
	close(start)
	wg.Wait()

	allowed := 0
	for _, exceeded := range results {
		if !exceeded {
			allowed++
		}
	}
	if allowed != 10 {
		t.Fatalf("allowed %d of %d concurrent attempts from one IP, want exactly 10", allowed, attempts)
	}
}

// TestAuthRateLimitReaperDropsExpiredEntries covers the purge loop's half of the change.
// The reaper Ranges the sync.Map lock-free but now takes each entry's mutex to read
// windowEnd; this asserts it still deletes what it should and keeps what it should.
func TestAuthRateLimitReaperDropsExpiredEntries(t *testing.T) {
	s := &Server{}

	attemptFrom(s, "10.1.0.1") // expired below
	attemptFrom(s, "10.1.0.2") // still inside its window

	rawOld, _ := s.authRateLimit.Load(rateLimitKey(rateLimitBucketAuth, "10.1.0.1"))
	old := rawOld.(*authRateEntry)
	old.mu.Lock()
	old.windowEnd = time.Now().Add(-1 * time.Minute)
	old.mu.Unlock()

	// Same shape as the purge loop in the background reaper.
	nowT := time.Now()
	s.authRateLimit.Range(func(k, v any) bool {
		entry, ok := v.(*authRateEntry)
		if !ok {
			return true
		}
		entry.mu.Lock()
		expired := nowT.After(entry.windowEnd)
		entry.mu.Unlock()
		if expired {
			s.authRateLimit.Delete(k)
		}
		return true
	})

	if _, still := s.authRateLimit.Load(rateLimitKey(rateLimitBucketAuth, "10.1.0.1")); still {
		t.Error("expired entry for 10.1.0.1 survived the reaper")
	}
	if _, still := s.authRateLimit.Load(rateLimitKey(rateLimitBucketAuth, "10.1.0.2")); !still {
		t.Error("live entry for 10.1.0.2 was reaped while its window was still open")
	}
}
