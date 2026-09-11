package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// The rate limiter keys on RemoteAddr, and chi's middleware.RealIP rewrote RemoteAddr from
// client-supplied headers UNCONDITIONALLY. Two ways that was exploitable here:
//
//   - The packaged nginx sets X-Forwarded-For to $proxy_add_x_forwarded_for, which APPENDS
//     to whatever the client sent. chi took the FIRST entry — the attacker's value.
//   - chi checks True-Client-IP before everything else, and the packaged nginx never sets
//     that header at all, so it passed straight through.
//
// Either let a caller rotate a fresh rate-limit bucket per request. Verified against a
// running server before the fix: 14 login attempts with rotating forged headers were never
// throttled, where 14 from one real source correctly 429'd after 10.

func requestFrom(peer string, headers map[string]string) *http.Request {
	r := httptest.NewRequest("POST", "/api/v1/auth/login", nil)
	r.RemoteAddr = peer
	for k, v := range headers {
		r.Header.Set(k, v)
	}
	return r
}

// observedRemoteAddr runs the middleware and reports what the handler would see.
func observedRemoteAddr(r *http.Request) string {
	var seen string
	trustedRealIP(http.HandlerFunc(func(_ http.ResponseWriter, rr *http.Request) {
		seen = rr.RemoteAddr
	})).ServeHTTP(httptest.NewRecorder(), r)
	return seen
}

func TestForwardedHeadersIgnoredFromUntrustedPeer(t *testing.T) {
	cases := []struct {
		name    string
		headers map[string]string
	}{
		{"True-Client-IP", map[string]string{"True-Client-IP": "1.2.3.4"}},
		{"X-Real-IP", map[string]string{"X-Real-IP": "1.2.3.4"}},
		{"X-Forwarded-For", map[string]string{"X-Forwarded-For": "1.2.3.4"}},
		{"all three", map[string]string{
			"True-Client-IP":  "1.2.3.4",
			"X-Real-IP":       "5.6.7.8",
			"X-Forwarded-For": "9.10.11.12",
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			const peer = "192.168.50.77:51000"
			got := observedRemoteAddr(requestFrom(peer, c.headers))
			if got != peer {
				t.Fatalf("a non-loopback peer must not be able to set its own key: got %q, want %q", got, peer)
			}
		})
	}
}

// The legitimate path must keep working, or every request through nginx would share one
// rate-limit bucket and one user's failures would lock out everyone else.
func TestForwardedHeadersHonouredFromLoopbackProxy(t *testing.T) {
	for _, peer := range []string{"127.0.0.1:40000", "[::1]:40000"} {
		got := observedRemoteAddr(requestFrom(peer, map[string]string{"X-Real-IP": "10.0.0.42"}))
		if got != "10.0.0.42" {
			t.Errorf("peer %s: expected the proxy's X-Real-IP to be honoured, got %q", peer, got)
		}
	}
}

// With $proxy_add_x_forwarded_for the trusted proxy APPENDS the address it actually saw,
// so the last entry is the only hop it vouched for. Taking the first — chi's behaviour —
// is exactly what let a client prepend a forged value.
func TestXForwardedForUsesTheLastHopNotTheFirst(t *testing.T) {
	got := observedRemoteAddr(requestFrom("127.0.0.1:40000", map[string]string{
		"X-Forwarded-For": "1.2.3.4, 10.0.0.42",
	}))
	if got == "1.2.3.4" {
		t.Fatal("took the client-supplied first entry — this is the bypass")
	}
	if got != "10.0.0.42" {
		t.Fatalf("expected the proxy-appended last hop, got %q", got)
	}
}

// True-Client-IP is not set by anything in this deployment, so it must never be consulted
// even from the proxy — otherwise a client could set it and nginx would pass it through.
func TestTrueClientIPIsNeverTrusted(t *testing.T) {
	got := observedRemoteAddr(requestFrom("127.0.0.1:40000", map[string]string{
		"True-Client-IP": "1.2.3.4",
	}))
	if got == "1.2.3.4" {
		t.Fatal("True-Client-IP must be ignored: nothing in this deployment sets it, so it is attacker-controlled")
	}
}

// Garbage must not clear or corrupt the peer address.
func TestMalformedForwardedValuesFallBackToThePeer(t *testing.T) {
	const peer = "127.0.0.1:40000"
	for _, v := range []string{"not-an-ip", "", "   ", "999.999.999.999"} {
		got := observedRemoteAddr(requestFrom(peer, map[string]string{"X-Real-IP": v}))
		if got != peer {
			t.Errorf("X-Real-IP=%q: expected fallback to the peer %q, got %q", v, peer, got)
		}
	}
}

func TestPeerIsLoopback(t *testing.T) {
	trusted := []string{"127.0.0.1:1", "[::1]:1", "127.0.0.53:9"}
	untrusted := []string{"192.168.50.77:1", "10.0.0.1:1", "8.8.8.8:1", "", "garbage"}

	for _, a := range trusted {
		if !peerIsLoopback(a) {
			t.Errorf("%q should be trusted as a local proxy", a)
		}
	}
	for _, a := range untrusted {
		if peerIsLoopback(a) {
			t.Errorf("%q must NOT be trusted", a)
		}
	}
}
