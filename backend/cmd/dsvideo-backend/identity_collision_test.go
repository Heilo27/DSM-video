package main

// TASK-931: "u_"+sanitizeID(username) gave distinct DSM users one account ("ryan.p",
// "ryan_p", "ryan-p" -> u_ryan_p; every all-non-ASCII name -> "u_"), and the FR-216 owner
// PIN reset accepted the colliding user's own DSM password. account_claims now records which
// DSM user owns each key. Existing accounts must keep their key and data untouched.

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// dsmAccepts makes DSM accept each listed user with that user's own password, returning the
// name as typed (authenticateDSM echoes the request's username).
func dsmAccepts(s *Server, passwords map[string]string) {
	s.dsmAuthOverride = func(_ context.Context, username, password, _, _ string) (*dsmUserInfo, error) {
		for user, pw := range passwords {
			if strings.EqualFold(strings.TrimSpace(username), user) && password == pw {
				return &dsmUserInfo{Username: username, DisplayName: username, SID: "test-sid"}, nil
			}
		}
		return nil, errors.New("invalid credentials")
	}
}

func newIdentityServer(t *testing.T) *Server {
	t.Helper()
	s, _ := newProfilesTestServer(t)
	s.cfg.JWTSecret = "identity-test-secret"
	dsmAccepts(s, map[string]string{
		"alice": "alice-pw", "ryan_p": "owner-pw", "ryan-p": "other-pw", "ryan.p": "third-pw",
		"日本": "jp-pw", "中文": "zh-pw",
	})
	return s
}

// loginKey signs in through the real REST handler and returns the account key it issued.
func loginKey(t *testing.T, s *Server, username, password string) string {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"username": username, "password": password})
	req := httptest.NewRequest("POST", "/api/v1/auth/login", strings.NewReader(string(body)))
	req.RemoteAddr = "192.0.2.10:5555"
	rec := httptest.NewRecorder()
	s.handleLogin(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("login %q: status %d body %s", username, rec.Code, rec.Body.String())
	}
	var resp loginResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("login %q: decode: %v", username, err)
	}
	return resp.User.ID
}

// An account that existed before the upgrade (rows under u_alice, no claim) signs in to the
// same key and sees its data, with any capitalisation DSM accepts.
func TestExistingAccountLogsInExactlyAsBefore(t *testing.T) {
	s := newIdentityServer(t)
	ownerID := seedOwnerProfile(t, s.db, "u_alice")
	if _, err := s.db.Exec(`INSERT INTO watchlist(item_id, user_id, profile_id, added_at) VALUES('it_1', 'u_alice', ?, '2026-01-01T00:00:00Z')`, ownerID); err != nil {
		t.Fatalf("seed pre-upgrade watchlist row: %v", err)
	}

	for _, typed := range []string{"alice", "Alice", " ALICE "} {
		if got := loginKey(t, s, typed, "alice-pw"); got != "u_alice" {
			t.Fatalf("login as %q: key %q, want the pre-upgrade key u_alice", typed, got)
		}
	}
	var n int
	_ = s.db.QueryRow(`SELECT COUNT(*) FROM watchlist WHERE user_id = 'u_alice'`).Scan(&n)
	if n != 1 {
		t.Fatalf("pre-upgrade watchlist rows under u_alice = %d, want 1 (untouched)", n)
	}
	_ = s.db.QueryRow(`SELECT COUNT(*) FROM profiles WHERE user_id = 'u_alice' AND is_owner = 1`).Scan(&n)
	if n != 1 {
		t.Fatalf("owner profiles under u_alice = %d, want exactly the pre-upgrade one", n)
	}
}

func TestPunctuationVariantsGetDistinctStableAccounts(t *testing.T) {
	s := newIdentityServer(t)
	owner := loginKey(t, s, "ryan_p", "owner-pw")
	if owner != "u_ryan_p" {
		t.Fatalf("first claimant key %q, want legacy u_ryan_p", owner)
	}
	dash := loginKey(t, s, "ryan-p", "other-pw")
	dot := loginKey(t, s, "ryan.p", "third-pw")
	if dash == owner || dot == owner || dash == dot {
		t.Fatalf("colliding DSM users share an account: ryan_p=%q ryan-p=%q ryan.p=%q", owner, dash, dot)
	}
	if !strings.HasPrefix(dash, "u_ryan_p_") || !strings.HasPrefix(dot, "u_ryan_p_") {
		t.Fatalf("distinct keys should keep the readable prefix: %q %q", dash, dot)
	}
	// Deterministic: the same DSM user always lands in the same account.
	if again := loginKey(t, s, "RYAN-P", "other-pw"); again != dash {
		t.Fatalf("ryan-p signed in to %q, then %q", dash, again)
	}
	if again := loginKey(t, s, "ryan_p", "owner-pw"); again != owner {
		t.Fatalf("claimant moved from %q to %q", owner, again)
	}
}

// Every all-non-ASCII username used to become the bare key "u_".
func TestNonASCIIUsernamesNoLongerShareTheBareKey(t *testing.T) {
	s := newIdentityServer(t)
	jp := loginKey(t, s, "日本", "jp-pw")
	zh := loginKey(t, s, "中文", "zh-pw")
	if jp == zh {
		t.Fatalf("two non-ASCII DSM users share account %q", jp)
	}
	if jp != "u_" {
		t.Fatalf("first non-ASCII user should keep the legacy key %q, got %q", "u_", jp)
	}
}

func resetOwnerPin(s *Server, userID, username, password string) (int, string) {
	req := authedRequest("POST", "/profiles/owner/pin/reset",
		`{"password":"`+password+`","newPin":"9999"}`, userID, username, "")
	req.RemoteAddr = "192.0.2.20:5555"
	rec := httptest.NewRecorder()
	profilesTestRouter(s).ServeHTTP(rec, req)
	var out struct {
		Error string `json:"error"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &out)
	return rec.Code, out.Error
}

// The FR-216 hole: a colliding DSM user holding a token for the shared key (any token issued
// before the upgrade) reset the owner PIN with THEIR OWN password. The check now compares the
// DSM user to the key's claimant.
func TestOwnerPinResetRefusesCollidingDSMUser(t *testing.T) {
	s := newIdentityServer(t)
	if key := loginKey(t, s, "ryan_p", "owner-pw"); key != "u_ryan_p" {
		t.Fatalf("setup: claimant key %q", key)
	}
	var before []byte
	_ = s.db.QueryRow(`SELECT pin_hash FROM profiles WHERE user_id = 'u_ryan_p' AND is_owner = 1`).Scan(&before)

	code, errCode := resetOwnerPin(s, "u_ryan_p", "ryan-p", "other-pw")
	if code != http.StatusForbidden || errCode != "password_incorrect" {
		t.Fatalf("colliding user's reset: got %d %q, want 403 password_incorrect", code, errCode)
	}
	var after []byte
	_ = s.db.QueryRow(`SELECT pin_hash FROM profiles WHERE user_id = 'u_ryan_p' AND is_owner = 1`).Scan(&after)
	if string(before) != string(after) {
		t.Fatalf("owner PIN changed by a colliding DSM user")
	}

	// The claimant's own reset still works.
	if code, errCode := resetOwnerPin(s, "u_ryan_p", "ryan_p", "owner-pw"); code != http.StatusOK {
		t.Fatalf("claimant's reset: got %d %q, want 200", code, errCode)
	}
}

// An existing account whose user has not signed in since the upgrade (old token, no claim
// yet) can still reset: the reset claims the key exactly as a sign-in would.
func TestOwnerPinResetWorksForUnclaimedPreUpgradeAccount(t *testing.T) {
	s := newIdentityServer(t)
	seedOwnerProfile(t, s.db, "u_alice")
	if code, errCode := resetOwnerPin(s, "u_alice", "alice", "alice-pw"); code != http.StatusOK {
		t.Fatalf("pre-upgrade account reset: got %d %q, want 200", code, errCode)
	}
	if key := loginKey(t, s, "alice", "alice-pw"); key != "u_alice" {
		t.Fatalf("after reset, alice signs in to %q, want u_alice", key)
	}
}

// Concurrent first sign-ins of two colliding users: each gets exactly one key, never the same.
func TestConcurrentClaimsNeverShareAKey(t *testing.T) {
	s := newIdentityServer(t)
	ctx := context.Background()
	var mu sync.Mutex
	keys := map[string]map[string]bool{"x.y": {}, "x-y": {}}
	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		for name := range keys {
			wg.Add(1)
			go func(name string) {
				defer wg.Done()
				k, err := s.accountKey(ctx, name)
				if err != nil {
					t.Errorf("accountKey(%q): %v", name, err)
					return
				}
				mu.Lock()
				keys[name][k] = true
				mu.Unlock()
			}(name)
		}
	}
	wg.Wait()
	if len(keys["x.y"]) != 1 || len(keys["x-y"]) != 1 {
		t.Fatalf("a user got more than one key: %v", keys)
	}
	for k := range keys["x.y"] {
		if keys["x-y"][k] {
			t.Fatalf("x.y and x-y share key %q", k)
		}
	}
}

func TestAccountClaimsMigrationIsIdempotent(t *testing.T) {
	s := newIdentityServer(t)
	loginKey(t, s, "alice", "alice-pw")
	for i := 0; i < 2; i++ {
		if err := migrate(s.db); err != nil {
			t.Fatalf("migrate re-run %d: %v", i, err)
		}
	}
	var n int
	_ = s.db.QueryRow(`SELECT COUNT(*) FROM account_claims WHERE user_id = 'u_alice' AND username = 'alice'`).Scan(&n)
	if n != 1 {
		t.Fatalf("claim lost or duplicated across migrate re-runs: %d", n)
	}
}
