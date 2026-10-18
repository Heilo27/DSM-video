package main

import (
	"net/http/httptest"
	"strings"
	"testing"
)

// TASK-1056: the playback response hands out absolute streamUrl / hlsMasterUrl /
// subtitle URLs built from requestBaseURL. They must point back at the exact
// address (scheme, host, port, path prefix) the client reached the server through,
// because the client plays them verbatim. Headers below are what the packaged DSM
// nginx config sets on every proxied request: X-Forwarded-Host = $http_host and
// X-Forwarded-Proto = $scheme.
func TestRequestBaseURL_TASK1056(t *testing.T) {
	const relayHost = "synr-us6.PRIMEAUNAS.direct.quickconnect.to:20876"

	cases := []struct {
		name    string
		path    string
		host    string
		xfHost  string
		xfProto string
		cfgBase string
		want    string
	}{
		{
			name: "LAN direct through DSM nginx on port 5000",
			path: "/api/v1/items/abc/playback", host: "192.168.50.148:5000",
			xfHost: "192.168.50.148:5000", xfProto: "http",
			cfgBase: "http://localhost:8090",
			want:    "http://192.168.50.148:5000",
		},
		{
			name: "request that arrived under the /dsvideo alias keeps the prefix",
			path: "/dsvideo/api/v1/items/abc/playback", host: "192.168.50.148:5000",
			xfHost: "192.168.50.148:5000", xfProto: "http",
			cfgBase: "http://localhost:8090",
			want:    "http://192.168.50.148:5000/dsvideo",
		},
		{
			name: "QuickConnect relay, nginx reports http: client only reaches the relay over https",
			path: "/api/v1/items/abc/playback", host: relayHost,
			xfHost: relayHost, xfProto: "http",
			cfgBase: "http://localhost:8090",
			want:    "https://" + relayHost,
		},
		{
			name: "QuickConnect relay, nginx reports https",
			path: "/api/v1/items/abc/playback", host: relayHost,
			xfHost: relayHost, xfProto: "https",
			cfgBase: "http://localhost:8090",
			want:    "https://" + relayHost,
		},
		{
			name: "QuickConnect relay under the /dsvideo alias",
			path: "/dsvideo/api/v1/items/abc/playback", host: relayHost,
			xfHost: relayHost, xfProto: "http",
			cfgBase: "http://localhost:8090",
			want:    "https://" + relayHost + "/dsvideo",
		},
		{
			name: "QuickConnect hole-punched direct host is https too",
			path: "/api/v1/items/abc/playback", host: "192-168-50-148.PRIMEAUNAS.direct.quickconnect.to:5001",
			xfHost: "192-168-50-148.PRIMEAUNAS.direct.quickconnect.to:5001", xfProto: "http",
			cfgBase: "http://localhost:8090",
			want:    "https://192-168-50-148.PRIMEAUNAS.direct.quickconnect.to:5001",
		},
		{
			name: "WAN direct HTTPS on DSM's external port",
			path: "/api/v1/items/abc/playback", host: "primeau.synology.me:5001",
			xfHost: "primeau.synology.me:5001", xfProto: "https",
			cfgBase: "http://localhost:8090",
			want:    "https://primeau.synology.me:5001",
		},
		{
			name: "multi-hop X-Forwarded-Proto uses the client-facing (first) value",
			path: "/api/v1/items/abc/playback", host: "primeau.synology.me:443",
			xfHost: "primeau.synology.me:443", xfProto: "https, http",
			cfgBase: "http://localhost:8090",
			want:    "https://primeau.synology.me:443",
		},
		{
			name: "no proxy: client talks to the backend port directly",
			path: "/api/v1/items/abc/playback", host: "192.168.50.148:8090",
			cfgBase: "http://localhost:8090",
			want:    "http://192.168.50.148:8090",
		},
		{
			name: "start script's empty override falls back to the request",
			path: "/api/v1/items/abc/playback", host: "192.168.50.148:5000",
			xfHost: "192.168.50.148:5000", xfProto: "http",
			cfgBase: "",
			want:    "http://192.168.50.148:5000",
		},
		{
			name: "loopback override is ignored",
			path: "/api/v1/items/abc/playback", host: "192.168.50.148:5000",
			xfHost: "192.168.50.148:5000", xfProto: "http",
			cfgBase: "http://127.0.0.1:8090",
			want:    "http://192.168.50.148:5000",
		},
		{
			name: "operator override pins every URL to one address",
			path: "/dsvideo/api/v1/items/abc/playback", host: relayHost,
			xfHost: relayHost, xfProto: "http",
			cfgBase: "https://media.example.com/",
			want:    "https://media.example.com",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest("GET", tc.path, nil)
			r.Host = tc.host
			if tc.xfHost != "" {
				r.Header.Set("X-Forwarded-Host", tc.xfHost)
			}
			if tc.xfProto != "" {
				r.Header.Set("X-Forwarded-Proto", tc.xfProto)
			}
			if got := requestBaseURL(r, tc.cfgBase); got != tc.want {
				t.Fatalf("requestBaseURL = %q, want %q", got, tc.want)
			}
		})
	}
}

// TASK-1056: the embedded web player (served at /dsvideo/, so state.baseURL ends in
// /dsvideo) used to rebuild the stream URL as state.baseURL + pathname. Now that the
// server's pathname keeps the /dsvideo prefix, that would double it to
// /dsvideo/dsvideo/api/v1/... and the player would 404. The page is one embedded file,
// so this asserts on its source, like web_quickconnect_test.go.
func TestWebPlayerDoesNotDoubleThePathPrefix_TASK1056(t *testing.T) {
	page := webPage(t)
	if strings.Contains(page, "state.baseURL + parsed.pathname") {
		t.Fatal("web player appends the server's path to state.baseURL; a /dsvideo base doubles the prefix")
	}
	body := jsFunctionBody(t, page, "playbackSourceURL")
	if !strings.Contains(body, "new URL(state.baseURL).origin") ||
		!strings.Contains(body, "origin + parsed.pathname + parsed.search") {
		t.Fatalf("playbackSourceURL must resolve the server's path against the ORIGIN of state.baseURL:\n%s", body)
	}
	if !strings.Contains(page, "const url = playbackSourceURL(rawUrl);") {
		t.Fatal("the play path no longer goes through playbackSourceURL")
	}
}
