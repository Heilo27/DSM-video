package main

// TASK-967 / OC-1119, OC-1120 (FR-117, FR-118): device pairing, observed through the real router
// the way the second device reaches it: the first device is signed in and asks for a code, the
// second is unsigned and redeems it. The server cannot tell iOS from tvOS (the code carries no
// platform), so "both directions" is the same exchange run once per generating account.
//
// pairing_test.go (TASK-972) covers the connection-details payload and the guess budget by
// calling the handlers directly with status-only checks; these two go through the router and
// assert the body the second device displays and the session it is handed.

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// pairRaw sends one request through the router with an optional bearer token and returns the
// status and decoded JSON body without the harness's "401 is a defect" rule, because the bad
// codes under test are legitimately 401.
func (e *qaEnv) pairRaw(method, path, body, bearer string) (int, map[string]any, string) {
	e.t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	rec := httptest.NewRecorder()
	e.h.ServeHTTP(rec, req)
	var js map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &js)
	return rec.Code, js, rec.Body.String()
}

func (e *qaEnv) pairingCode(u qaUser) string {
	e.t.Helper()
	r := e.do(u, "POST", "/auth/pairing/generate", "", "")
	wantOK(e.t, r, 200)
	code := r.str("code")
	if len(code) != 6 {
		e.t.Fatalf("generate answered code %q, want 6 digits (body %s)", code, r.raw)
	}
	return code
}

// OC-1119 · given the first device signed in as alice and the second unsigned, when the second
// enters alice's code, then it receives a session for alice's account (and only alice's), with
// no password or address typed; the same holds when bob's device is the generator.
// Red if: the exchange issues a token for another account, issues none, or returns a token the
// API will not accept (the second device would be "paired" but locked out).
func TestOC1119_PairedDeviceGetsTheGeneratingAccountsSession(t *testing.T) {
	e := newQAEnv(t)
	e.s.pairingCodes = make(map[string]pairingEntry)
	aliceOwner := e.ownerID(qaAlice)
	bobOwner := e.ownerID(qaBob)
	if aliceOwner == bobOwner {
		t.Fatalf("precondition: the two accounts must have different owner profiles, both %s", aliceOwner)
	}

	for _, c := range []struct {
		gen       qaUser
		wantOwner string
		other     string
	}{
		{qaAlice, aliceOwner, bobOwner},
		{qaBob, bobOwner, aliceOwner},
	} {
		code := e.pairingCode(c.gen)
		status, js, raw := e.pairRaw("POST", "/auth/pairing/exchange", `{"code":"`+code+`"}`, "")
		if status != 200 {
			t.Fatalf("%s: exchange answered %d %s, want 200", c.gen.name, status, raw)
		}
		token, _ := js["token"].(string)
		user, _ := js["user"].(map[string]any)
		if token == "" || user["id"] != c.gen.id || user["username"] != c.gen.name {
			t.Fatalf("%s: exchange body %s, want a token and user %s/%s", c.gen.name, raw, c.gen.id, c.gen.name)
		}

		// The session works and is the generator's account: its profile list holds the
		// generator's owner profile and not the other account's.
		status, js, raw = e.pairRaw("GET", "/profiles", "", token)
		if status != 200 {
			t.Fatalf("%s: GET /profiles with the paired token answered %d %s, want 200", c.gen.name, status, raw)
		}
		var ids []string
		profs, _ := js["profiles"].([]any)
		for _, p := range profs {
			ids = append(ids, fmt.Sprint(p.(map[string]any)["id"]))
		}
		hasOwn, hasOther := false, false
		for _, id := range ids {
			hasOwn = hasOwn || id == c.wantOwner
			hasOther = hasOther || id == c.other
		}
		if !hasOwn || hasOther || len(ids) != 1 {
			t.Errorf("%s: paired session lists profiles %v, want exactly [%s]", c.gen.name, ids, c.wantOwner)
		}
	}
}

// OC-1120 · given a pairing screen, when a wrong code, an expired code and an already-used code
// are entered one after another, then each is rejected as a code problem (401
// invalid_or_expired_code) with no token or user in the body, so the device stays unpaired;
// and a fresh valid code afterwards still pairs. An empty code is a 400 about the missing code.
// Red if: any bad code is accepted, the body of a rejection carries a token, the rejection
// stops naming the code, or a failed attempt poisons the next valid one.
func TestOC1120_BadCodesAreRejectedAboutTheCodeAndAFreshOnePairs(t *testing.T) {
	e := newQAEnv(t)
	e.s.pairingCodes = make(map[string]pairingEntry)

	live := e.pairingCode(qaAlice)
	wrong := fmt.Sprintf("%06d", (mustAtoi(t, live)+1)%1_000_000)

	expired := e.pairingCode(qaAlice)
	e.s.pairingMu.Lock()
	ent := e.s.pairingCodes[expired]
	ent.expiresAt = time.Now().Add(-time.Second)
	e.s.pairingCodes[expired] = ent
	e.s.pairingMu.Unlock()

	used := e.pairingCode(qaAlice)
	if status, _, raw := e.pairRaw("POST", "/auth/pairing/exchange", `{"code":"`+used+`"}`, ""); status != 200 {
		t.Fatalf("precondition: first redemption of the 'used' code answered %d %s", status, raw)
	}

	for _, c := range []struct{ name, code string }{
		{"wrong", wrong}, {"expired", expired}, {"already used", used},
	} {
		status, js, raw := e.pairRaw("POST", "/auth/pairing/exchange", `{"code":"`+c.code+`"}`, "")
		if status != http.StatusUnauthorized || js["error"] != "invalid_or_expired_code" {
			t.Errorf("%s code: got %d %s, want 401 {error:invalid_or_expired_code}", c.name, status, raw)
		}
		if _, has := js["token"]; has {
			t.Errorf("%s code: the rejection carried a token: %s", c.name, raw)
		}
		if _, has := js["user"]; has {
			t.Errorf("%s code: the rejection carried a user: %s", c.name, raw)
		}
	}

	// Empty code: the second device is told the code is missing, not that one was wrong.
	status, js, raw := e.pairRaw("POST", "/auth/pairing/exchange", `{"code":""}`, "")
	if status != http.StatusBadRequest || js["error"] != "missing_code" {
		t.Errorf("empty code: got %d %s, want 400 {error:missing_code}", status, raw)
	}

	// A fresh valid code pairs: the three failures left no lock or partial state behind.
	fresh := e.pairingCode(qaAlice)
	status, js, raw = e.pairRaw("POST", "/auth/pairing/exchange", `{"code":"`+fresh+`"}`, "")
	if status != 200 || js["token"] == nil || js["token"] == "" {
		t.Errorf("fresh code after three rejections: got %d %s, want 200 with a token", status, raw)
	}
	// The still-unredeemed first code is also still good: only the guesses failed.
	status, _, raw = e.pairRaw("POST", "/auth/pairing/exchange", `{"code":"`+live+`"}`, "")
	if status != 200 {
		t.Errorf("the untouched live code after three rejections: got %d %s, want 200", status, raw)
	}
}
