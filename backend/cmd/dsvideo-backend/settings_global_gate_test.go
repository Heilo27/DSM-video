package main

// TASK-932 (SEC-6): the global tmdb_api_key swaps the shared TMDb client and kicks a full
// rescan, so it is an admin action under FR-250: a restricted profile on the admin's own
// DSM account is refused, exactly as on /admin/*. Per-user settings stay writable by any
// profile.

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"testing"

	"dsvideo/backend/internal/rating"
)

func newSettingsGateServer(t *testing.T) (*Server, *sql.DB, string, string) {
	t.Helper()
	s, db := newProfilesTestServer(t)
	s.cfg.AdminUser = "alice"
	owner, kid := "p_alice_owner", "p_alice_kid"
	for _, p := range []struct {
		id    string
		level int
		isOwn int
	}{{owner, rating.MaxLevel, 1}, {kid, 1, 0}} {
		if _, err := db.Exec(
			`INSERT INTO profiles(id, user_id, name, avatar, max_age_level, pin_hash, is_owner, created_at)
			 VALUES(?, 'u_alice', ?, '', ?, NULL, ?, '2026-01-01T00:00:00Z')`,
			p.id, p.id, p.level, p.isOwn); err != nil {
			t.Fatalf("seed profile %s: %v", p.id, err)
		}
	}
	return s, db, owner, kid
}

func putSettings(s *Server, profile, body string) (int, string) {
	req := authedRequest("PUT", "/api/v1/settings", body, "u_alice", "alice", profile)
	rec := serveWithResolver(s, http.HandlerFunc(s.handlePutSettings), true, req)
	var out struct {
		Error string `json:"error"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &out)
	return rec.Code, out.Error
}

func globalTMDbKeyRow(t *testing.T, db *sql.DB) (string, bool) {
	t.Helper()
	var v string
	err := db.QueryRow(`SELECT value FROM settings WHERE key = 'tmdb_api_key' AND user_id = ''`).Scan(&v)
	if err == sql.ErrNoRows {
		return "", false
	}
	if err != nil {
		t.Fatalf("read settings: %v", err)
	}
	return v, true
}

func TestRestrictedProfileCannotSetGlobalTMDbKey(t *testing.T) {
	s, db, _, kid := newSettingsGateServer(t)

	code, errCode := putSettings(s, kid, `{"settings":{"tmdb_api_key":"attacker-key"}}`)
	if code != http.StatusForbidden || errCode != "profile_restricted" {
		t.Fatalf("restricted profile setting tmdb_api_key: got %d %q, want 403 profile_restricted", code, errCode)
	}
	if v, ok := globalTMDbKeyRow(t, db); ok {
		t.Fatalf("global key was written by a restricted profile: %q", v)
	}
	if s.tmdbClient != nil {
		t.Fatalf("TMDb client was reinitialised by a restricted profile")
	}

	// A mixed request is refused whole: the per-user key in it is not written either.
	code, _ = putSettings(s, kid, `{"settings":{"tmdb_api_key":"x","theme":"dark"}}`)
	if code != http.StatusForbidden {
		t.Fatalf("mixed request from restricted profile: got %d, want 403", code)
	}
	var n int
	_ = db.QueryRow(`SELECT COUNT(*) FROM settings WHERE key = 'theme'`).Scan(&n)
	if n != 0 {
		t.Fatalf("refused request still wrote %d per-user row(s)", n)
	}
}

func TestRestrictedProfileCanStillSetPerUserSettings(t *testing.T) {
	s, db, _, kid := newSettingsGateServer(t)
	if code, errCode := putSettings(s, kid, `{"settings":{"theme":"dark"}}`); code != http.StatusOK {
		t.Fatalf("restricted profile per-user setting: got %d %q, want 200", code, errCode)
	}
	var v string
	if err := db.QueryRow(`SELECT value FROM settings WHERE key = 'theme' AND user_id = 'u_alice'`).Scan(&v); err != nil || v != "dark" {
		t.Fatalf("per-user setting not stored: %q %v", v, err)
	}
}

func TestUnrestrictedAdminProfileCanSetGlobalTMDbKey(t *testing.T) {
	s, db, owner, _ := newSettingsGateServer(t)
	// An empty value clears the key without launching a rescan in the test.
	if code, errCode := putSettings(s, owner, `{"settings":{"tmdb_api_key":""}}`); code != http.StatusOK {
		t.Fatalf("admin owner profile: got %d %q, want 200", code, errCode)
	}
	if _, ok := globalTMDbKeyRow(t, db); !ok {
		t.Fatalf("admin owner profile's global key write was not stored")
	}
}

func TestNonAdminStillGetsAdminRequired(t *testing.T) {
	s, _, owner, _ := newSettingsGateServer(t)
	s.cfg.AdminUser = "someone-else"
	if code, errCode := putSettings(s, owner, `{"settings":{"tmdb_api_key":""}}`); code != http.StatusForbidden || errCode != "admin_required" {
		t.Fatalf("non-admin: got %d %q, want 403 admin_required", code, errCode)
	}
}
