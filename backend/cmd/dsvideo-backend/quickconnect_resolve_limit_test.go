package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

// TASK-1053: /auth/quickconnect/resolve is unauthenticated and forwards a caller-supplied
// ID to Synology. Without a limit and a format check the NAS is an open lookup relay.

func resolveServer(calls *atomic.Int32) *Server {
	return &Server{quickConnectResolver: func(ctx context.Context, id string) ([]qcCandidate, error) {
		calls.Add(1)
		return []qcCandidate{{BaseURL: "https://example.invalid:5001", Kind: "direct"}}, nil
	}}
}

func postResolve(s *Server, ip, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest("POST", "/auth/quickconnect/resolve", strings.NewReader(body))
	r.RemoteAddr = ip + ":51000"
	w := httptest.NewRecorder()
	s.handleQuickConnectResolve(w, r)
	return w
}

func TestQuickConnectResolveIsRateLimitedPerIP(t *testing.T) {
	var calls atomic.Int32
	s := resolveServer(&calls)
	for i := 0; i < 10; i++ {
		if w := postResolve(s, "10.1.0.1", `{"quickConnectId":"my-nas"}`); w.Code != http.StatusOK {
			t.Fatalf("request %d inside the budget got %d: %s", i+1, w.Code, w.Body.String())
		}
	}
	w := postResolve(s, "10.1.0.1", `{"quickConnectId":"my-nas"}`)
	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("11th request got %d, want 429", w.Code)
	}
	if !strings.Contains(w.Body.String(), `"rate_limit_exceeded"`) {
		t.Errorf("body %q is not the shared limiter shape", w.Body.String())
	}
	if got := w.Header().Get("Retry-After"); got != "60" {
		t.Errorf("Retry-After = %q, want 60", got)
	}
	if calls.Load() != 10 {
		t.Errorf("resolver called %d times, want 10 (the limited request must not go out)", calls.Load())
	}
	if w := postResolve(s, "10.1.0.2", `{"quickConnectId":"my-nas"}`); w.Code != http.StatusOK {
		t.Errorf("a different IP was limited by the first: %d", w.Code)
	}
}

func TestQuickConnectResolveRejectsMalformedIDsBeforeTheOutboundCall(t *testing.T) {
	bad := []string{
		"has space", "a/b", "a?b=c", "a@evil.test", "-leading-dash", "a.b",
		strings.Repeat("a", 65), `id\u0000x`, `id\nx`, "http://evil.test",
	}
	for i, id := range bad {
		var calls atomic.Int32
		s := resolveServer(&calls)
		// A distinct IP per case so the limiter cannot be what rejects it.
		ip := "10.1.1." + string(rune('1'+i))
		w := postResolve(s, ip, `{"quickConnectId":"`+id+`"}`)
		if w.Code != http.StatusBadRequest || !strings.Contains(w.Body.String(), `"invalid_quickconnect_id"`) {
			t.Errorf("id %q: got %d %s, want 400 invalid_quickconnect_id", id, w.Code, w.Body.String())
		}
		if calls.Load() != 0 {
			t.Errorf("id %q reached the outbound resolver", id)
		}
	}
}

func TestQuickConnectResolveStillResolvesAValidID(t *testing.T) {
	var calls atomic.Int32
	s := resolveServer(&calls)
	w := postResolve(s, "10.1.2.1", `{"quickConnectId":"  My-NAS_1  "}`)
	if w.Code != http.StatusOK || calls.Load() != 1 {
		t.Fatalf("valid id: code %d calls %d body %s", w.Code, calls.Load(), w.Body.String())
	}
}

// The limiter runs before validation, so a sweep of junk IDs burns the same budget.
func TestQuickConnectResolveCountsRejectedRequestsAgainstTheLimit(t *testing.T) {
	var calls atomic.Int32
	s := resolveServer(&calls)
	for i := 0; i < 10; i++ {
		postResolve(s, "10.1.3.1", `{"quickConnectId":"bad id"}`)
	}
	if w := postResolve(s, "10.1.3.1", `{"quickConnectId":"my-nas"}`); w.Code != http.StatusTooManyRequests {
		t.Fatalf("after 10 rejected requests a valid one got %d, want 429", w.Code)
	}
	if calls.Load() != 0 {
		t.Errorf("resolver called %d times", calls.Load())
	}
}
