package main

// TASK-929 follow-up (TASK-919): a Synology WebAPI GET login carries the DSM password, the
// 2FA one-time code and DSM's encrypted login blob in its query string. The request line
// chi's Logger prints must never contain them, and the login handler must still read them.

import (
	"bytes"
	"log"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
)

// loginCredentialParams maps each credential parameter to a value distinctive enough that a
// substring hit in the log can only be a leak.
var loginCredentialParams = map[string]string{
	"passwd":       "Hunter2-dsm-password-7731",
	"otp_code":     "918273",
	"__cIpHeRtExT": "rsa-blob-QmFzZTY0Q2lwaGVy",
}

// productionLogChain wires redaction around chi's REAL request logger (writing to buf) in
// the order main() uses, and records the query the handler saw.
func productionLogChain(buf *bytes.Buffer, saw *url.Values) http.Handler {
	r := chi.NewRouter()
	r.Use(redactSensitiveParams)
	r.Use(middleware.RequestLogger(&middleware.DefaultLogFormatter{Logger: log.New(buf, "", 0), NoColor: true}))
	r.Use(restoreTrueURL)
	r.Get("/webapi/auth.cgi", func(w http.ResponseWriter, req *http.Request) {
		*saw = req.URL.Query()
		w.WriteHeader(http.StatusOK)
	})
	return r
}

func TestLoginCredentialsNeverReachTheRequestLog(t *testing.T) {
	q := url.Values{"api": {"SYNO.API.Auth"}, "method": {"login"}, "account": {"alice"}}
	for k, v := range loginCredentialParams {
		q.Set(k, v)
	}
	var buf bytes.Buffer
	var saw url.Values
	h := productionLogChain(&buf, &saw)
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest("GET", "/webapi/auth.cgi?"+q.Encode(), nil))

	logged := buf.String()
	if logged == "" {
		t.Fatal("the request logger printed nothing; the test is not observing the log")
	}
	for k, v := range loginCredentialParams {
		if strings.Contains(logged, v) || strings.Contains(logged, url.QueryEscape(v)) {
			t.Errorf("%s value leaked into the request log: %q", k, logged)
		}
		if got := saw.Get(k); got != v {
			t.Errorf("handler read %s = %q, want the real value %q: login would fail", k, got, v)
		}
	}
	if !strings.Contains(logged, "alice") || !strings.Contains(logged, "SYNO.API.Auth") {
		t.Errorf("non-secret parameters must stay readable in the log: %q", logged)
	}
}

// Each credential alone triggers redaction: the middleware must not skip a request because
// it carries none of the session tokens.
func TestEachLoginCredentialIsRedactedOnItsOwn(t *testing.T) {
	for k, v := range loginCredentialParams {
		out, redacted := redactedQuery(url.Values{k: {v}, "account": {"alice"}})
		if !redacted {
			t.Errorf("%s alone was not redacted", k)
			continue
		}
		if out.Get(k) != "[REDACTED]" {
			t.Errorf("%s = %q after redaction, want [REDACTED]", k, out.Get(k))
		}
		if out.Get("account") != "alice" {
			t.Errorf("account changed to %q while redacting %s", out.Get("account"), k)
		}
	}
}
