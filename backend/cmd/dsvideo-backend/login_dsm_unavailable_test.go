package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// 2026-10-21: DSM's cold auth.cgi outlasted the server's timeout and every remote sign-in read
// "Incorrect username or password" for a password DSM never checked.
// Red if: a DSM that could not be asked is reported as a wrong password.
func TestLoginReportsUnreachableDSMAsUnavailable(t *testing.T) {
	cases := map[string]error{
		"timeout": fmt.Errorf("dsm request failed: %w", context.DeadlineExceeded),
		"refused": fmt.Errorf("dsm request failed: connection refused"),
		"decode":  fmt.Errorf("dsm auth unavailable: decode error"),
	}
	for name, dsmErr := range cases {
		t.Run(name, func(t *testing.T) {
			s, _ := newProfilesTestServer(t)
			s.dsmAuthOverride = func(context.Context, string, string, string, string) (*dsmUserInfo, error) {
				return nil, dsmErr
			}
			req := httptest.NewRequest("POST", "/api/v1/auth/login",
				strings.NewReader(`{"username":"alice","password":"alice-pw"}`))
			req.RemoteAddr = "192.0.2.20:5555"
			rec := httptest.NewRecorder()
			s.handleLogin(rec, req)
			if rec.Code != http.StatusServiceUnavailable || !strings.Contains(rec.Body.String(), "dsm_unavailable") {
				t.Fatalf("got %d %s, want 503 dsm_unavailable", rec.Code, rec.Body.String())
			}
		})
	}
}

// Red if: DSM answering "wrong password" (error 400) stops being invalid_credentials.
func TestLoginKeepsRealRejectionAsInvalidCredentials(t *testing.T) {
	s, _ := newProfilesTestServer(t)
	s.dsmAuthOverride = func(context.Context, string, string, string, string) (*dsmUserInfo, error) {
		return nil, fmt.Errorf("invalid credentials")
	}
	req := httptest.NewRequest("POST", "/api/v1/auth/login",
		strings.NewReader(`{"username":"alice","password":"nope"}`))
	req.RemoteAddr = "192.0.2.21:5555"
	rec := httptest.NewRecorder()
	s.handleLogin(rec, req)
	if rec.Code != http.StatusUnauthorized || !strings.Contains(rec.Body.String(), "invalid_credentials") {
		t.Fatalf("got %d %s, want 401 invalid_credentials", rec.Code, rec.Body.String())
	}
}
