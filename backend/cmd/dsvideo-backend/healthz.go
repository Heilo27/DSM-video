package main

// Package-lifecycle health (TASK-1080, FRD-003).
//
// start-stop-status must be able to tell "a process is bound to :8090" from "THIS build,
// running as THIS user, is serving and its database answers". A pid file and a live pid
// prove neither (the 2026-11 incident: a stale root-owned backend held the port while a
// fresh one died on bind and the script still reported success).
//
//   GET /api/v1/healthz      the endpoint (also reachable under /dsvideo/api/v1)
//   dsvideo-backend --healthcheck [--expect-pid N] [--expect-uid N] [--expect-version V]
//                            the same check from the shell, with no curl dependency
//
// Kept in its own file so it does not collide with other work in main.go.

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strconv"
	"time"
)

// processStart is when this process began, reported by healthz so a caller can tell a
// fresh start from a long-running one.
var processStart = time.Now()

// healthzDBTimeout bounds the database probe so a wedged DB reports unhealthy instead of
// hanging the health gate.
const healthzDBTimeout = 2 * time.Second

// healthzDirect reports whether the request came straight from this machine with no proxy
// in between. Only such callers (the start script, the --healthcheck flag) get process
// detail. A request through nginx, or from another host, gets only {ok, version}: pid and
// uid are of no use to a LAN client and healthz is unauthenticated.
//
// trustedRealIP has already rewritten r.RemoteAddr from the forwarded headers by the time
// we run, so a proxied request looks like an ordinary client address. The raw headers are
// therefore checked as well: nginx always sets X-Real-IP and X-Forwarded-For.
func healthzDirect(r *http.Request) bool {
	if r.Header.Get("X-Real-IP") != "" || r.Header.Get("X-Forwarded-For") != "" ||
		r.Header.Get("Forwarded") != "" || r.Header.Get("True-Client-IP") != "" {
		return false
	}
	return peerIsLoopback(r.RemoteAddr)
}

// handleHealthz - GET /api/v1/healthz (public).
//
// 200 when the database answers, 503 when it does not. Direct callers also get pid, uid,
// startedAt and the db detail.
func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	dbOK := false
	if s.db != nil {
		ctx, cancel := context.WithTimeout(r.Context(), healthzDBTimeout)
		var one int
		dbOK = s.db.QueryRowContext(ctx, "SELECT 1").Scan(&one) == nil && one == 1
		cancel()
	}

	status := http.StatusOK
	if !dbOK {
		status = http.StatusServiceUnavailable
	}
	body := map[string]any{"ok": dbOK, "version": BuildVersion}
	if healthzDirect(r) {
		body["pid"] = os.Getpid()
		body["uid"] = os.Getuid()
		body["startedAt"] = processStart.UTC().Format(time.RFC3339)
		body["db"] = map[string]any{"ok": dbOK}
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, status, body)
}

// runHealthcheck implements `dsvideo-backend --healthcheck`. It asks the server listening
// on this process's configured port (DSVIDEO_PORT) for /api/v1/healthz over loopback and
// returns the process exit code: 0 healthy and matching every --expect-* given, 1 otherwise.
// The reason goes to stderr, one line; a healthy result prints one line to stdout.
func runHealthcheck(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("healthcheck", flag.ContinueOnError)
	fs.SetOutput(stderr)
	expectPID := fs.Int("expect-pid", 0, "require healthz to report this pid")
	expectUID := fs.Int("expect-uid", -1, "require healthz to report this uid")
	expectVersion := fs.String("expect-version", "", "require healthz to report this build version")
	timeout := fs.Duration("timeout", 3*time.Second, "request timeout")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	_, port, err := net.SplitHostPort(loadConfig().ListenAddr)
	if err != nil {
		fmt.Fprintf(stderr, "healthcheck: bad listen address: %v\n", err)
		return 1
	}
	url := "http://" + net.JoinHostPort("127.0.0.1", port) + "/api/v1/healthz"

	client := &http.Client{Timeout: *timeout}
	resp, err := client.Get(url)
	if err != nil {
		fmt.Fprintf(stderr, "healthcheck: %v\n", err)
		return 1
	}
	defer resp.Body.Close()

	var h struct {
		OK      bool   `json:"ok"`
		Version string `json:"version"`
		PID     *int   `json:"pid"`
		UID     *int   `json:"uid"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(&h); err != nil {
		fmt.Fprintf(stderr, "healthcheck: HTTP %d, unreadable body: %v\n", resp.StatusCode, err)
		return 1
	}
	if resp.StatusCode != http.StatusOK || !h.OK {
		fmt.Fprintf(stderr, "healthcheck: unhealthy (HTTP %d, ok=%v)\n", resp.StatusCode, h.OK)
		return 1
	}
	if h.PID == nil || h.UID == nil {
		// Detail is only given to direct callers; losing it means something is proxying
		// loopback traffic, or a different program owns the port.
		fmt.Fprintln(stderr, "healthcheck: response has no pid/uid; not a direct DSVideo healthz")
		return 1
	}
	if *expectPID != 0 && *h.PID != *expectPID {
		fmt.Fprintf(stderr, "healthcheck: pid mismatch: port is served by pid %d, expected %d\n", *h.PID, *expectPID)
		return 1
	}
	if *expectUID >= 0 && *h.UID != *expectUID {
		fmt.Fprintf(stderr, "healthcheck: uid mismatch: server runs as uid %d, expected %d\n", *h.UID, *expectUID)
		return 1
	}
	if *expectVersion != "" && h.Version != *expectVersion {
		fmt.Fprintf(stderr, "healthcheck: version mismatch: server is %q, expected %q\n", h.Version, *expectVersion)
		return 1
	}
	fmt.Fprintf(stdout, "ok pid=%s uid=%s version=%s\n", strconv.Itoa(*h.PID), strconv.Itoa(*h.UID), h.Version)
	return 0
}
