package main

// TASK-919 item 8: DSM's trusted-device token lets a login skip the 2FA prompt. DSM returns
// it as "did" and takes it back as "device_id"; a GET login puts it in the request line,
// which chi's Logger prints. Neither name's value may reach the log, and the login handler
// must still read the real value.

import (
	"bytes"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

var deviceTokenParams = map[string]string{
	"device_id": "trusted-device-token-5ZQ8w1",
	"did":       "dsm-did-token-K7p2Xv",
}

func TestTrustedDeviceTokenNeverReachesTheRequestLog(t *testing.T) {
	q := url.Values{"api": {"SYNO.API.Auth"}, "method": {"login"}, "account": {"alice"}}
	for k, v := range deviceTokenParams {
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
	for k, v := range deviceTokenParams {
		if strings.Contains(logged, v) || strings.Contains(logged, url.QueryEscape(v)) {
			t.Errorf("%s value leaked into the request log: %q", k, logged)
		}
		if got := saw.Get(k); got != v {
			t.Errorf("handler read %s = %q, want the real value %q: trusted-device login would fail", k, got, v)
		}
	}
	if !strings.Contains(logged, "alice") || !strings.Contains(logged, "SYNO.API.Auth") {
		t.Errorf("non-secret parameters must stay readable in the log: %q", logged)
	}
}

// Each name alone triggers redaction: a re-login that carries only the device token (no
// password in the query, no session id) must still be redacted.
func TestTrustedDeviceTokenIsRedactedOnItsOwn(t *testing.T) {
	for k, v := range deviceTokenParams {
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
