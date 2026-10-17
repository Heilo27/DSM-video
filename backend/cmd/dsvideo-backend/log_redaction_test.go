package main

// TASK-929: request-shaped log lines must never carry credentials. The catch-all used to
// print req.URL.String() and 200 bytes of body, below restoreTrueURL, so a live DSM SID or a
// login form's passwd landed in the NAS package log.

import (
	"bytes"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
)

// captureStdLog redirects the standard logger for one test.
func captureStdLog(t *testing.T) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })
	return &buf
}

// The production middleware order (main.go: redactSensitiveParams, Logger, restoreTrueURL)
// with the real catch-all, so the catch-all sees the true URL exactly as it does on the NAS.
func TestUnhandledRequestLogCarriesNoCredentials(t *testing.T) {
	const (
		sid      = "SIDSECRET-must-not-be-logged"
		queryPW  = "QUERYPW-must-not-be-logged"
		bodyPW   = "BODYPW-must-not-be-logged"
		bodyOTP  = "424242"
		unrouted = "/webapi/NotARealEndpoint.cgi"
	)
	stdlog := captureStdLog(t)
	var chiLine strings.Builder

	r := chi.NewRouter()
	r.Use(redactSensitiveParams)
	r.Use(middleware.RequestLogger(&middleware.DefaultLogFormatter{Logger: log.New(&chiLine, "", 0), NoColor: true}))
	r.Use(restoreTrueURL)
	r.NotFound(logUnhandledRequest)

	req := httptest.NewRequest("POST", unrouted+"?api=SYNO.Foo&_sid="+sid+"&passwd="+queryPW,
		strings.NewReader("passwd="+bodyPW+"&otp_code="+bodyOTP))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
	got := stdlog.String()
	if !strings.Contains(got, "UNHANDLED POST "+unrouted) {
		t.Fatalf("catch-all no longer logs method and path: %q", got)
	}
	for _, secret := range []string{sid, queryPW, bodyPW, bodyOTP, "passwd", "_sid"} {
		if strings.Contains(got, secret) {
			t.Errorf("catch-all log line contains %q: %q", secret, got)
		}
	}
	// The access-log line above it must still hide the SID (redactSensitiveParams).
	if strings.Contains(chiLine.String(), sid) {
		t.Errorf("request log line contains the SID: %q", chiLine.String())
	}
}

func TestNoSIDLogShowsCookieNamesNotValues(t *testing.T) {
	got := cookieNames("did=device-123; other_app_session=VALUE-must-not-be-logged; theme=dark")
	if strings.Contains(got, "VALUE-must-not-be-logged") || strings.Contains(got, "device-123") {
		t.Fatalf("cookieNames leaked a value: %q", got)
	}
	if got != "did,other_app_session,theme" {
		t.Fatalf("cookieNames = %q, want sorted names only", got)
	}
	if cookieNames("") != "" {
		t.Fatalf("empty Cookie header should yield no names")
	}
}

// The old 16-character prefix printed a short SID in full. The fingerprint must never
// contain the SID or any 8-character run of it, and must be stable so lines correlate.
func TestSIDFingerprintNeverRevealsTheSID(t *testing.T) {
	for _, sid := range []string{"ohOCjwhHhwghw", "kXHhVnfS6d4PYU2K5Y_hyE7zWbb_3X8lv7ZAgtK3cOuJiO"} {
		fp := sidFingerprint(sid)
		for i := 0; i+8 <= len(sid); i++ {
			if strings.Contains(fp, sid[i:i+8]) {
				t.Fatalf("fingerprint %q contains part of SID %q", fp, sid)
			}
		}
		if fp != sidFingerprint(sid) {
			t.Fatalf("fingerprint not stable for %q", sid)
		}
	}
	if sidFingerprint("a") == sidFingerprint("b") {
		t.Fatalf("distinct SIDs share a fingerprint")
	}
}
