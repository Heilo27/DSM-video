package main

// TASK-1048: every `server_error` response leaves a log line naming the endpoint and the
// underlying error, so an on-device failure that only said "try again" can be traced on the
// NAS. Each case forces the real failing step (the entropy source), not the logging helper.

import (
	"bytes"
	"context"
	"errors"
	"log"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type failingEntropy struct{}

func (failingEntropy) Read([]byte) (int, error) { return 0, errors.New("entropy source offline") }

// breakEntropy makes every random read fail until the test ends.
func breakEntropy(t *testing.T) {
	t.Helper()
	saved := entropy
	entropy = failingEntropy{}
	t.Cleanup(func() { entropy = saved })
}

func captureServerErrorLog(t *testing.T) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	resetFailureSites() // the 5xx throttle is process-wide; a test starts with every site quiet
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })
	return &buf
}

// The `server_error` code may only be written by writeServerError (in profiles.go), which logs.
// A direct writeErr(..., "server_error") anywhere else is the silent path TASK-1048 removed.
func TestServerErrorIsWrittenOnlyByTheLoggingHelper(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	total := 0
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		src, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		n := strings.Count(string(src), `"server_error"`)
		total += n
		if n > 0 && f != "profiles.go" {
			t.Errorf("%s writes %q %d time(s); route it through writeServerError", f, "server_error", n)
		}
	}
	if total != 1 {
		t.Errorf("found %d literal %q writes in non-test source, want exactly 1 (inside writeServerError)", total, "server_error")
	}
}

func wantServerErrorLog(t *testing.T, logs *bytes.Buffer, method, path string, secrets ...string) {
	t.Helper()
	out := logs.String()
	var line string
	for _, l := range strings.Split(out, "\n") {
		if strings.Contains(l, "server_error") {
			line = l
		}
	}
	if line == "" {
		t.Fatalf("no server_error log line; log was:\n%s", out)
	}
	for _, want := range []string{method + " " + path, "entropy source offline"} {
		if !strings.Contains(line, want) {
			t.Errorf("server_error log line %q is missing %q", line, want)
		}
	}
	for _, s := range secrets {
		if strings.Contains(out, s) {
			t.Errorf("log leaks %q:\n%s", s, out)
		}
	}
}

func TestServerErrorLogs_CreateWithPinNamesEndpointAndCause(t *testing.T) {
	e := newQAEnv(t)
	e.setOwnerPin(qaAlice, "0420")
	logs := captureServerErrorLog(t)
	breakEntropy(t)
	r := e.create(qaAlice, "0420", "Kid", 1, map[string]any{"pin": "7391"})
	wantErr(t, r, 500, "server_error")
	wantServerErrorLog(t, logs, "POST", "/profiles", "7391", "0420")
}

func TestServerErrorLogs_CreateWithoutPinNamesEndpointAndCause(t *testing.T) {
	e := newQAEnv(t)
	e.setOwnerPin(qaAlice, "0420")
	logs := captureServerErrorLog(t)
	breakEntropy(t)
	r := e.create(qaAlice, "0420", "Kid", 1, nil)
	wantErr(t, r, 500, "server_error")
	wantServerErrorLog(t, logs, "POST", "/profiles", "0420")
}

func TestServerErrorLogs_UpdatePinNamesEndpointAndCause(t *testing.T) {
	e := newQAEnv(t)
	e.setOwnerPin(qaAlice, "0420")
	kid := e.mustCreate(qaAlice, "0420", "Kid", 1, nil)
	logs := captureServerErrorLog(t)
	breakEntropy(t)
	r := e.do(qaAlice, "PATCH", "/profiles/"+kid, jb(map[string]any{"ownerPin": "0420", "pin": "7391"}), "")
	wantErr(t, r, 500, "server_error")
	wantServerErrorLog(t, logs, "PATCH", "/profiles/"+kid, "7391", "0420")
}

func TestServerErrorLogs_OwnerPinResetNamesEndpointAndCause(t *testing.T) {
	e := newQAEnv(t)
	e.setOwnerPin(qaAlice, "0420")
	e.s.dsmAuthOverride = func(_ context.Context, _, password, _, _ string) (*dsmUserInfo, error) {
		if password == "hunter2-secret" {
			return &dsmUserInfo{Username: "alice"}, nil
		}
		return nil, errors.New("invalid credentials")
	}
	logs := captureServerErrorLog(t)
	breakEntropy(t)
	r := e.do(qaAlice, "POST", "/profiles/owner/pin/reset",
		jb(map[string]any{"password": "hunter2-secret", "newPin": "5555"}), "")
	wantErr(t, r, 500, "server_error")
	wantServerErrorLog(t, logs, "POST", "/profiles/owner/pin/reset", "hunter2-secret", "5555")
}
