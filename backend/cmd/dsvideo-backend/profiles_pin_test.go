package main

// FRD-002 FR-213..FR-217 verification: PIN verify, lockout, shared counter, storage, owner
// reset through DSM. Written from the FRD/API doc. Expected values are literals.

import (
	"bytes"
	"context"
	"errors"
	"log"
	"os"
	"strings"
	"testing"
	"time"
)

// qaClock is a controllable clock for the PIN limiter.
type qaClock struct{ t time.Time }

func (c *qaClock) now() time.Time          { return c.t }
func (c *qaClock) advance(d time.Duration) { c.t = c.t.Add(d) }

func newQAClock(e *qaEnv) *qaClock {
	c := &qaClock{t: time.Date(2026, 10, 17, 12, 0, 0, 0, time.UTC)}
	setPinClock(e.s, c.now)
	return c
}

func (e *qaEnv) verify(u qaUser, id, pin string) qaResp {
	e.t.Helper()
	return e.do(u, "POST", "/profiles/"+id+"/pin/verify", jb(map[string]any{"pin": pin}), "")
}

func wantLocked(t *testing.T, r qaResp, min, max int) {
	t.Helper()
	wantErr(t, r, 429, "pin_locked")
	if got := r.num("retryAfterSeconds"); got < min || got > max {
		t.Errorf("retryAfterSeconds = %d, want %d..%d (%s)", got, min, max, r.raw)
	}
}

// AC-002-19 / FR-215. 5 wrong -> the 6th attempt, even correct, is 429 pin_locked with ~300s.
// After the wait the correct PIN works and the counter resets (4 attempts left again).
// Red if: lock threshold is 6, the correct PIN bypasses the lock, retryAfterSeconds is wrong,
// the lock never expires, or success does not reset the counter.
func TestAC00219_FiveWrongLocksSixthEvenIfCorrect_ExpiresAndResets(t *testing.T) {
	e := newQAEnv(t)
	clk := newQAClock(e)
	e.setOwnerPin(qaAlice, "0420")
	kid := e.mustCreate(qaAlice, "0420", "Kid", 1, map[string]any{"pin": "1111"})

	for i, want := range []int{4, 3, 2, 1, 0} {
		r := e.verify(qaAlice, kid, "9999")
		wantErr(t, r, 403, "pin_incorrect")
		if got := r.num("attemptsRemaining"); got != want {
			t.Errorf("wrong attempt %d: attemptsRemaining = %d, want %d", i+1, got, want)
		}
		if _, ok := r.js["attemptsRemaining"]; !ok {
			t.Errorf("wrong attempt %d: attemptsRemaining missing: %s", i+1, r.raw)
		}
	}
	wantLocked(t, e.verify(qaAlice, kid, "1111"), 295, 300) // the correct PIN is refused
	wantLocked(t, e.verify(qaAlice, kid, "9999"), 295, 300)

	clk.advance(120 * time.Second)
	wantLocked(t, e.verify(qaAlice, kid, "1111"), 175, 180) // the countdown moves
	clk.advance(179 * time.Second)                           // 299 s in: still locked
	wantLocked(t, e.verify(qaAlice, kid, "1111"), 1, 1)
	clk.advance(2 * time.Second) // 301 s in
	wantOK(t, e.verify(qaAlice, kid, "1111"), 200)

	// The success reset the counter: a fresh run of wrong attempts starts at 4 remaining.
	r := e.verify(qaAlice, kid, "9999")
	wantErr(t, r, 403, "pin_incorrect")
	if r.num("attemptsRemaining") != 4 {
		t.Errorf("after success the counter should be fresh, got %s", r.raw)
	}
}

// FR-215: a success mid-run resets the consecutive-failure count, so 4+ok+4 never locks.
func TestAC00219_SuccessResetsConsecutiveFailures(t *testing.T) {
	e := newQAEnv(t)
	newQAClock(e)
	e.setOwnerPin(qaAlice, "0420")
	kid := e.mustCreate(qaAlice, "0420", "Kid", 1, map[string]any{"pin": "1111"})
	for round := 0; round < 3; round++ {
		for i := 0; i < 4; i++ {
			wantErr(t, e.verify(qaAlice, kid, "9999"), 403, "pin_incorrect")
		}
		wantOK(t, e.verify(qaAlice, kid, "1111"), 200)
	}
}

// FR-215: each further lockout doubles the wait (300, 600, 1200, 2400, 3600) up to 1 hour.
// Red if doubling is missing, the cap is absent, or the cap is exceeded.
func TestAC00219_LockoutDoublesAndCapsAtOneHour(t *testing.T) {
	e := newQAEnv(t)
	clk := newQAClock(e)
	e.setOwnerPin(qaAlice, "0420")
	kid := e.mustCreate(qaAlice, "0420", "Kid", 1, map[string]any{"pin": "1111"})

	waits := []int{300, 600, 1200, 2400, 3600, 3600}
	for n, w := range waits {
		for i := 0; i < 5; i++ {
			wantErr(t, e.verify(qaAlice, kid, "9999"), 403, "pin_incorrect")
		}
		wantLocked(t, e.verify(qaAlice, kid, "1111"), w-5, w)
		clk.advance(time.Duration(w-1) * time.Second)
		wantLocked(t, e.verify(qaAlice, kid, "1111"), 1, 1)
		clk.advance(2 * time.Second)
		_ = n
	}
}

// FR-215: one failure counter per profile and shared by every PIN-accepting endpoint. Wrong
// attempts via verify AND via owner-PIN management calls add up on the owner profile; once
// locked, a management call with the CORRECT owner PIN is refused with pin_locked too.
// Red if verify and management keep separate counters (an attacker gets 5+5 guesses), or if
// the lock does not cover management calls.
func TestAC00219_OwnerCounterSharedBetweenVerifyAndManagement(t *testing.T) {
	e := newQAEnv(t)
	clk := newQAClock(e)
	owner := e.setOwnerPin(qaAlice, "0420")
	kid := e.mustCreate(qaAlice, "0420", "Kid", 1, nil)

	for i := 0; i < 3; i++ {
		wantErr(t, e.verify(qaAlice, owner, "9999"), 403, "pin_incorrect")
	}
	r := e.do(qaAlice, "PATCH", "/profiles/"+kid, jb(map[string]any{"ownerPin": "8888", "name": "X"}), "")
	wantErr(t, r, 403, "pin_incorrect")
	if r.num("attemptsRemaining") != 1 {
		t.Errorf("4th wrong (3 verify + 1 management) should leave 1, got %s", r.raw)
	}
	r = e.do(qaAlice, "DELETE", "/profiles/"+kid, jb(map[string]any{"ownerPin": "8888"}), "")
	wantErr(t, r, 403, "pin_incorrect")
	if r.num("attemptsRemaining") != 0 {
		t.Errorf("5th wrong should leave 0, got %s", r.raw)
	}

	// Locked: verify, create, edit and delete with the CORRECT owner PIN are all refused.
	wantLocked(t, e.verify(qaAlice, owner, "0420"), 295, 300)
	wantLocked(t, e.create(qaAlice, "0420", "New", 2, nil), 290, 300)
	wantLocked(t, e.do(qaAlice, "PATCH", "/profiles/"+kid, jb(map[string]any{"ownerPin": "0420", "name": "Y"}), ""), 290, 300)
	wantLocked(t, e.do(qaAlice, "DELETE", "/profiles/"+kid, jb(map[string]any{"ownerPin": "0420"}), ""), 290, 300)
	if e.profileByName(qaAlice, "Kid") == nil || e.profileByName(qaAlice, "New") != nil {
		t.Errorf("a locked-out management call still changed data")
	}

	// Another profile / another account is not locked by alice's owner lock.
	e.setOwnerPin(qaBob, "1357")
	wantOK(t, e.verify(qaBob, e.ownerID(qaBob), "1357"), 200)
	wantOK(t, e.verify(qaAlice, kid, "anything-no-pin-set-ignored-by-server"), 200) // kid has no PIN: ok immediately

	clk.advance(301 * time.Second)
	wantOK(t, e.create(qaAlice, "0420", "New", 2, nil), 201)
}

// FR-215: counters are per profile - locking the kid does not lock the owner's own checks.
func TestAC00219_CounterIsPerProfile(t *testing.T) {
	e := newQAEnv(t)
	newQAClock(e)
	owner := e.setOwnerPin(qaAlice, "0420")
	kid := e.mustCreate(qaAlice, "0420", "Kid", 1, map[string]any{"pin": "1111"})
	for i := 0; i < 5; i++ {
		wantErr(t, e.verify(qaAlice, kid, "9999"), 403, "pin_incorrect")
	}
	wantLocked(t, e.verify(qaAlice, kid, "1111"), 295, 300)
	wantOK(t, e.verify(qaAlice, owner, "0420"), 200)
	// ...and the owner can still manage (reset the kid's PIN), because the OWNER counter is clean.
	wantOK(t, e.do(qaAlice, "PATCH", "/profiles/"+kid, jb(map[string]any{"ownerPin": "0420", "pin": "2222"}), ""), 200)
	// Changing the kid's PIN clears that profile's lock so the new PIN is usable (FR-211 reset path).
	wantOK(t, e.verify(qaAlice, kid, "2222"), 200)
}

// FR-213 negative paths on verify: unknown/other-account id -> 403 unknown_profile (not 404,
// not 401); no-PIN profile -> ok without a body; bad body -> 400.
func TestFR213_VerifyEdgeCases(t *testing.T) {
	e := newQAEnv(t)
	newQAClock(e)
	e.setOwnerPin(qaAlice, "0420")
	bobOwner := e.setOwnerPin(qaBob, "1357")
	open := e.mustCreate(qaAlice, "0420", "Open", 2, nil)

	wantErr(t, e.verify(qaAlice, bobOwner, "1357"), 403, "unknown_profile") // correct PIN, wrong account
	wantErr(t, e.verify(qaAlice, "pf_doesnotexist", "0000"), 403, "unknown_profile")
	r := e.do(qaAlice, "POST", "/profiles/"+open+"/pin/verify", "", "")
	wantOK(t, r, 200)
	if r.js["ok"] != true {
		t.Errorf("verify on a PIN-less profile: %s", r.raw)
	}
	// The probe above must not have burned bob's counter.
	for i := 0; i < 4; i++ {
		wantErr(t, e.verify(qaAlice, bobOwner, "0000"), 403, "unknown_profile")
	}
	r = e.verify(qaBob, bobOwner, "0000")
	wantErr(t, r, 403, "pin_incorrect")
	if r.num("attemptsRemaining") != 4 {
		t.Errorf("cross-account probes consumed bob's attempts: %s", r.raw)
	}
	// Bad JSON on a PIN-protected profile.
	wantErr(t, e.do(qaBob, "POST", "/profiles/"+bobOwner+"/pin/verify", "{not json", ""), 400, "invalid_json")
}

// AC-002-20 / FR-203 / FR-214. PIN 0420: not in the database file, not in the WAL, not in any
// response, not in the server log; GET /profiles shows hasPin only; two profiles with the same
// PIN get different stored values (salted); the stored value is a hash, not the PIN.
// Red if the PIN (or a reversible form like "p:0420") is persisted, echoed or logged, or if
// the hash is unsalted.
func TestAC00220_PinNeverStoredLoggedOrReturned(t *testing.T) {
	var logBuf bytes.Buffer
	log.SetOutput(&logBuf)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })

	e := newQAEnv(t)
	owner := e.setOwnerPin(qaAlice, "0420")
	kid := e.mustCreate(qaAlice, "0420", "Kid", 1, map[string]any{"pin": "0420"})
	wantOK(t, e.verify(qaAlice, kid, "0420"), 200)
	wantErr(t, e.verify(qaAlice, kid, "0421"), 403, "pin_incorrect")
	wantErr(t, e.create(qaAlice, "9990", "Nope", 1, nil), 403, "pin_incorrect")
	e.do(qaAlice, "PATCH", "/profiles/"+kid, jb(map[string]any{"ownerPin": "0420", "name": "Kid2", "pin": "0420"}), "")
	e.do(qaAlice, "GET", "/profiles", "", "")

	// Stored value: a salted slow hash, never the PIN, and different per profile.
	var ownerHash, kidHash string
	if err := e.db.QueryRow(`SELECT pin_hash FROM profiles WHERE id=?`, owner).Scan(&ownerHash); err != nil {
		t.Fatal(err)
	}
	if err := e.db.QueryRow(`SELECT pin_hash FROM profiles WHERE id=?`, kid).Scan(&kidHash); err != nil {
		t.Fatal(err)
	}
	if ownerHash == "" || kidHash == "" {
		t.Fatalf("PINs not stored: owner=%q kid=%q", ownerHash, kidHash)
	}
	if ownerHash == kidHash {
		t.Errorf("identical PIN gave identical stored hashes: unsalted (FR-214)")
	}
	for _, h := range []string{ownerHash, kidHash} {
		if strings.Contains(h, "0420") || h == "0420" {
			t.Errorf("stored value contains the PIN: %q", h)
		}
		if len(h) < 40 {
			t.Errorf("stored value %q is too short to be a salted hash", h)
		}
	}

	// Raw file bytes, after folding the WAL into the main file AND with the WAL itself.
	if _, err := e.db.Exec(`PRAGMA wal_checkpoint(TRUNCATE)`); err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{e.dbPath, e.dbPath + "-wal"} {
		b, err := os.ReadFile(f)
		if err != nil {
			if errors.Is(err, os.ErrNotExist) && strings.HasSuffix(f, "-wal") {
				continue
			}
			t.Fatal(err)
		}
		if len(b) == 0 && strings.HasSuffix(f, "-wal") {
			continue
		}
		if i := bytes.Index(b, []byte("0420")); i >= 0 {
			lo, hi := max(0, i-20), min(len(b), i+20)
			t.Errorf("PIN 0420 found in %s at byte %d: %q", f, i, b[lo:hi])
		}
		if len(b) < 4096 && !strings.HasSuffix(f, "-wal") {
			t.Errorf("%s is implausibly small (%d bytes): the scan proves nothing", f, len(b))
		}
	}
	// The PIN is in the backups-in-waiting too: any pre-profiles copy next to the DB.
	// (Migration ran on an empty DB; nothing there can hold a PIN set afterwards.)

	for i, body := range e.bodies {
		if strings.Contains(body, "0420") {
			t.Errorf("response %d contains the PIN: %s", i, body)
		}
		for _, bad := range []string{"pin_hash", "pinHash", "pbkdf2"} {
			if strings.Contains(body, bad) {
				t.Errorf("response %d exposes hash material %q: %s", i, bad, body)
			}
		}
	}
	if strings.Contains(logBuf.String(), "0420") {
		t.Errorf("server log contains the PIN:\n%s", logBuf.String())
	}

	list := e.do(qaAlice, "GET", "/profiles", "", "")
	for _, p := range e.profiles(qaAlice) {
		if p["hasPin"] != true {
			t.Errorf("profile %v should report hasPin true", p["name"])
		}
		if _, ok := p["pin"]; ok {
			t.Errorf("profile exposes a pin field: %v", p)
		}
	}
	_ = list
}

// AC-002-21 / FR-216 / FR-217. Correct DSM password -> new owner PIN set (old one stops
// working, the new one works). Wrong password -> 403 password_incorrect, NOT 401, PIN unchanged.
// Red if the password is not checked, if it answers 401, or if a wrong-password call still
// changes the PIN.
func TestAC00221_OwnerPinResetViaDSMPassword(t *testing.T) {
	e := newQAEnv(t)
	newQAClock(e)
	fakeDSMLogin(e.s, "alice", "dsm-secret")
	owner := e.setOwnerPin(qaAlice, "0420")
	reset := func(body map[string]any) qaResp {
		return e.do(qaAlice, "POST", "/profiles/owner/pin/reset", jb(body), "")
	}

	wantErr(t, reset(map[string]any{"password": "wrong", "newPin": "7777"}), 403, "password_incorrect")
	wantErr(t, reset(map[string]any{"password": "", "newPin": "7777"}), 403, "password_incorrect")
	wantErr(t, reset(map[string]any{"newPin": "7777"}), 403, "password_incorrect")
	wantOK(t, e.verify(qaAlice, owner, "0420"), 200) // unchanged
	wantErr(t, e.verify(qaAlice, owner, "7777"), 403, "pin_incorrect")

	wantErr(t, reset(map[string]any{"password": "dsm-secret", "newPin": "12"}), 400, "invalid_pin_format")
	wantErr(t, reset(map[string]any{"password": "dsm-secret"}), 400, "invalid_pin_format")
	wantOK(t, e.verify(qaAlice, owner, "0420"), 200)

	r := reset(map[string]any{"password": "dsm-secret", "newPin": "7777"})
	wantOK(t, r, 200)
	if r.js["ok"] != true {
		t.Errorf("reset response: %s", r.raw)
	}
	wantErr(t, e.verify(qaAlice, owner, "0420"), 403, "pin_incorrect")
	wantOK(t, e.verify(qaAlice, owner, "7777"), 200)
	wantOK(t, e.create(qaAlice, "7777", "Kid", 1, nil), 201) // the new PIN also gates management
}

// FR-216: the reset also clears a lockout on the owner PIN (the point of a forgotten-PIN
// path), and the password must belong to THIS account, not merely to some DSM user.
func TestAC00221_ResetClearsLockoutAndRequiresThisAccountsPassword(t *testing.T) {
	e := newQAEnv(t)
	newQAClock(e)
	// DSM accepts bob's credentials, whoever asks.
	e.s.dsmAuthOverride = func(_ context.Context, username, password, _, _ string) (*dsmUserInfo, error) {
		switch {
		case strings.EqualFold(username, "alice") && password == "alice-pw":
			return &dsmUserInfo{Username: "alice"}, nil
		case password == "bob-pw":
			return &dsmUserInfo{Username: "bob"}, nil // DSM says "yes, this is bob" for a request made as alice
		}
		return nil, errors.New("invalid credentials")
	}
	owner := e.setOwnerPin(qaAlice, "0420")
	for i := 0; i < 5; i++ {
		wantErr(t, e.verify(qaAlice, owner, "9999"), 403, "pin_incorrect")
	}
	wantLocked(t, e.verify(qaAlice, owner, "0420"), 295, 300)

	wantErr(t, e.do(qaAlice, "POST", "/profiles/owner/pin/reset", jb(map[string]any{"password": "bob-pw", "newPin": "5555"}), ""), 403, "password_incorrect")
	wantLocked(t, e.verify(qaAlice, owner, "0420"), 280, 300) // still locked and unchanged

	wantOK(t, e.do(qaAlice, "POST", "/profiles/owner/pin/reset", jb(map[string]any{"password": "alice-pw", "newPin": "5555"}), ""), 200)
	wantOK(t, e.verify(qaAlice, owner, "5555"), 200)
}

// FR-216 / API doc: DSM unreachable -> 503 dsm_unavailable (never password_incorrect);
// DSM says the account is no longer allowed -> 403 permission_denied. Neither changes the PIN.
func TestAC00221_DSMUnavailableAndPermissionDenied(t *testing.T) {
	e := newQAEnv(t)
	newQAClock(e)
	owner := e.setOwnerPin(qaAlice, "0420")
	body := jb(map[string]any{"password": "whatever", "newPin": "5555"})

	for _, err := range []error{
		errors.New("dsm request failed: dial tcp: connection refused"),
		errors.New("dsm auth unavailable: no usable answer"),
		context.DeadlineExceeded,
	} {
		e.s.dsmAuthOverride = func(context.Context, string, string, string, string) (*dsmUserInfo, error) { return nil, err }
		wantErr(t, e.do(qaAlice, "POST", "/profiles/owner/pin/reset", body, ""), 503, "dsm_unavailable")
	}
	e.s.dsmAuthOverride = func(context.Context, string, string, string, string) (*dsmUserInfo, error) {
		return nil, &dsmPermissionError{}
	}
	wantErr(t, e.do(qaAlice, "POST", "/profiles/owner/pin/reset", body, ""), 403, "permission_denied")
	e.s.dsmAuthOverride = func(context.Context, string, string, string, string) (*dsmUserInfo, error) {
		return nil, errors.New("dsm error code 400")
	}
	wantErr(t, e.do(qaAlice, "POST", "/profiles/owner/pin/reset", body, ""), 403, "password_incorrect")

	wantOK(t, e.verify(qaAlice, owner, "0420"), 200) // PIN never changed
}

// FR-216: the reset is subject to the sign-in rate limit (10 per 60 s per IP). The 11th call
// is 429 rate_limit_exceeded and must not reach DSM.
func TestAC00221_ResetIsSubjectToSignInRateLimit(t *testing.T) {
	e := newQAEnv(t)
	newQAClock(e)
	calls := 0
	e.s.dsmAuthOverride = func(context.Context, string, string, string, string) (*dsmUserInfo, error) {
		calls++
		return nil, errors.New("invalid credentials")
	}
	e.setOwnerPin(qaAlice, "0420")
	var last qaResp
	for i := 0; i < 12; i++ {
		last = e.do(qaAlice, "POST", "/profiles/owner/pin/reset", jb(map[string]any{"password": "x", "newPin": "5555"}), "")
		if last.code == 429 {
			break
		}
	}
	wantErr(t, last, 429, "rate_limit_exceeded")
	if calls > 10 {
		t.Errorf("DSM was asked %d times; the limiter should stop calls after 10", calls)
	}
}
