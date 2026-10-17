package main

// TASK-931 follow-up (TASK-919): tokens (30 days) and saved WebAPI sessions issued before
// account_claims existed still carry the old shared account key. "ryan.p" and "ryan_p" both
// held u_ryan_p. Once "ryan.p" claims u_ryan_p, a pre-upgrade credential of "ryan_p" for
// u_ryan_p must stop working (REST 401, WebAPI the expired-session error) so that client
// signs in again and gets its own key. The owner's credentials, and credentials for a key
// nobody has claimed, keep working.

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

const sharedKey = "u_ryan_p" // legacy key of both "ryan.p" and "ryan_p"

// claimShared signs "ryan.p" in through the real accountKey, claiming the shared key.
func claimShared(t *testing.T, s *Server) {
	t.Helper()
	key, err := s.accountKey(context.Background(), "ryan.p")
	if err != nil || key != sharedKey {
		t.Fatalf("ryan.p accountKey = %q, %v; want %s", key, err, sharedKey)
	}
}

// restStatus sends GET /profiles with a token for (sub, usr) through the real router.
func restStatus(t *testing.T, e *qaEnv, sub, usr string) (int, string) {
	t.Helper()
	tok, err := e.s.issueToken(sub, usr)
	if err != nil {
		t.Fatalf("issueToken: %v", err)
	}
	req := httptest.NewRequest("GET", "/profiles", nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	rec := httptest.NewRecorder()
	e.h.ServeHTTP(rec, req)
	var body map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &body)
	code, _ := body["error"].(string)
	return rec.Code, code
}

func TestStaleTokenOfAnotherDSMUserIsRejected(t *testing.T) {
	e := newQAEnv(t)
	claimShared(t, e.s)
	for i := 1; i <= 2; i++ { // the second request is answered from the claim cache
		if code, errCode := restStatus(t, e, sharedKey, "ryan_p"); code != http.StatusUnauthorized || errCode != "invalid_token" {
			t.Errorf("request %d: ryan_p's pre-upgrade token for %s answered %d %q, want 401 invalid_token", i, sharedKey, code, errCode)
		}
	}
	// Signing in again gives ryan_p a key of its own, and that token works.
	own, err := e.s.accountKey(context.Background(), "ryan_p")
	if err != nil || own == sharedKey {
		t.Fatalf("ryan_p re-login key = %q, %v; want a distinct key", own, err)
	}
	if code, _ := restStatus(t, e, own, "ryan_p"); code != http.StatusOK {
		t.Errorf("ryan_p's new token answered %d, want 200", code)
	}
}

func TestOwnersPreUpgradeTokenKeepsWorking(t *testing.T) {
	e := newQAEnv(t)
	claimShared(t, e.s)
	// DSM usernames are case-insensitive. The first request reads account_claims, the rest
	// are answered from the claim cache; both paths must fold case.
	for _, usr := range []string{"Ryan.P", "RYAN.P", "ryan.p"} {
		if code, errCode := restStatus(t, e, sharedKey, usr); code != http.StatusOK {
			t.Errorf("owner token (usr %q) answered %d %q, want 200", usr, code, errCode)
		}
	}
}

func TestTokenForUnclaimedKeyKeepsWorking(t *testing.T) {
	e := newQAEnv(t)
	// Single-user install, nobody has signed in since the upgrade: no claims at all.
	if code, errCode := restStatus(t, e, "u_alice", "alice"); code != http.StatusOK {
		t.Errorf("pre-upgrade single-user token answered %d %q, want 200", code, errCode)
	}
}

// saveSession stores a WebAPI session the way a pre-upgrade server persisted it, then
// restores it through the real startup loader.
func saveSession(t *testing.T, s *Server, sid, userID, username string) {
	t.Helper()
	persistSession(s.db, &WebAPISession{SID: sid, UserID: userID, Username: username, Token: "t", DeviceID: "d", CreatedAt: time.Now()})
	t.Cleanup(func() { webAPISessions.Delete(sid) })
	loadPersistedSessions(s.db)
	if webAPISessions.Get(sid) == nil {
		t.Fatalf("session %s not restored by loadPersistedSessions", sid)
	}
}

func webAPIRequest(path string) *http.Request {
	req := httptest.NewRequest("GET", path, nil)
	req.Header.Set("User-Agent", "curl/8") // not DS Video: no DSM re-validation fallback
	return req
}

func persistedSessionCount(t *testing.T, s *Server, sid string) int {
	t.Helper()
	var n int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM webapi_sessions WHERE sid = ?`, sid).Scan(&n); err != nil {
		t.Fatalf("count webapi_sessions: %v", err)
	}
	return n
}

func TestStaleWebAPISessionOfAnotherDSMUserIsDropped(t *testing.T) {
	s, _ := newProfilesTestServer(t)
	const sid = "sid-stale-ryan_p"
	saveSession(t, s, sid, sharedKey, "ryan_p")
	claimShared(t, s)

	if got := s.getWebAPISession(webAPIRequest("/webapi/entry.cgi?_sid=" + sid)); got != nil {
		t.Errorf("ryan_p's saved session for %s was honoured; it must be treated as expired", sharedKey)
	}
	if webAPISessions.Get(sid) != nil || persistedSessionCount(t, s, sid) != 0 {
		t.Error("the stale session was not deleted from memory and SQLite: it would be restored on the next start")
	}
}

func TestStaleWebAPISessionCannotResume(t *testing.T) {
	s, _ := newProfilesTestServer(t)
	const sid = "sid-stale-resume"
	saveSession(t, s, sid, sharedKey, "ryan_p")
	claimShared(t, s)

	rec := httptest.NewRecorder()
	s.handleWebAPIAuth(rec, webAPIRequest("/webapi/auth.cgi?api=SYNO.API.Auth&method=resume&session=DSVideo&_sid="+sid), "resume")
	var body struct {
		Success bool `json:"success"`
		Error   struct {
			Code int `json:"code"`
		} `json:"error"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &body)
	if body.Success || body.Error.Code != 106 {
		t.Errorf("resume of a stale session answered %s, want error 106 (session timeout)", rec.Body.String())
	}
}

func TestOwnersWebAPISessionKeepsWorking(t *testing.T) {
	s, _ := newProfilesTestServer(t)
	claimShared(t, s)
	const owner, unclaimed = "sid-owner-ryan.p", "sid-unclaimed-alice"
	saveSession(t, s, owner, sharedKey, "ryan.p")
	saveSession(t, s, unclaimed, "u_alice", "alice")
	for _, sid := range []string{owner, unclaimed} {
		if got := s.getWebAPISession(webAPIRequest("/webapi/entry.cgi?_sid=" + sid)); got == nil {
			t.Errorf("session %s was rejected; the key's owner and unclaimed keys must keep working", sid)
		}
	}
}
