package main

import (
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// TASK-1082 acceptance tests. Each names the AC it pins and what makes it red.

func fromIP(ip, target string) *http.Request {
	r := httptest.NewRequest(http.MethodPost, target, nil)
	r.RemoteAddr = ip + ":51000"
	return r
}

// ---- P1-1: every DSM-forwarding branch is rate-limited per client IP ----

// Red if: the request over budget from one address still reaches DSM.
func TestDSMAuthPassthroughIsLimitedPerIP(t *testing.T) {
	s := &Server{}
	for i := 1; i <= dsmAuthPassthroughMax; i++ {
		if s.dsmAuthPassthroughLimited(httptest.NewRecorder(), fromIP("10.9.0.1", "/webapi/auth.cgi")) {
			t.Fatalf("request %d limited; budget is %d", i, dsmAuthPassthroughMax)
		}
	}
	w := httptest.NewRecorder()
	if !s.dsmAuthPassthroughLimited(w, fromIP("10.9.0.1", "/webapi/auth.cgi")) {
		t.Fatal("request over budget was not limited")
	}
	if w.Header().Get("Retry-After") == "" {
		t.Error("limited response carries no Retry-After")
	}
	if s.dsmAuthPassthroughLimited(httptest.NewRecorder(), fromIP("10.9.0.2", "/webapi/auth.cgi")) {
		t.Error("a second address was limited by the first one's traffic")
	}
	if s.dsmMetaPassthroughLimited(httptest.NewRecorder(), fromIP("10.9.0.1", "/webapi/entry.cgi")) {
		t.Error("meta bucket shares the auth bucket's counter")
	}
}

// Red if: the DSM.Info forward path (handleWebAPIDSMInfo) is not counted.
func TestDSMInfoForwardIsLimited(t *testing.T) {
	s := &Server{}
	var last *httptest.ResponseRecorder
	for i := 0; i <= dsmMetaPassthroughMax; i++ {
		last = httptest.NewRecorder()
		s.handleWebAPIDSMInfo(last, fromIP("10.9.1.1", "/webapi/entry.cgi"), "getinfo")
	}
	if got := last.Body.String(); !strings.Contains(got, "407") {
		t.Fatalf("request %d not refused with 407: %s", dsmMetaPassthroughMax+1, got)
	}
}

// ---- P1-3: unknown _sid validation ----

func guardServer(validate func(string) (string, error)) (*Server, *sidValidationGuard) {
	s := &Server{}
	g := s.sidGuardFor()
	g.validate = validate
	return s, g
}

// Red if: a replayed invalid SID reaches DSM more than once inside the TTL.
func TestUnknownSIDNegativeCache(t *testing.T) {
	var calls atomic.Int32
	s, g := guardServer(func(string) (string, error) { calls.Add(1); return "", errDSMSessionInvalid })
	clock := time.Unix(1_000_000, 0)
	g.now = func() time.Time { return clock }
	for i := 0; i < 5; i++ {
		if _, err := s.validateUnknownSID(fromIP("10.8.0.1", "/x"), "bad-sid"); err == nil {
			t.Fatalf("attempt %d accepted an invalid SID", i)
		}
	}
	if calls.Load() != 1 {
		t.Fatalf("DSM called %d times for one replayed SID, want 1", calls.Load())
	}
	clock = clock.Add(sidNegativeTTL + time.Second)
	_, _ = s.validateUnknownSID(fromIP("10.8.0.1", "/x"), "bad-sid")
	if calls.Load() != 2 {
		t.Fatalf("after TTL DSM called %d times, want 2", calls.Load())
	}
}

// Red if: a transport failure is cached, locking a valid SID out for a minute.
func TestUnknownSIDTransportErrorIsNotCached(t *testing.T) {
	var calls atomic.Int32
	s, _ := guardServer(func(string) (string, error) { calls.Add(1); return "", errors.New("connection refused") })
	for i := 0; i < 3; i++ {
		_, _ = s.validateUnknownSID(fromIP("10.8.0.2", "/x"), "sid")
	}
	if calls.Load() != 3 {
		t.Fatalf("DSM called %d times, want 3", calls.Load())
	}
}

// Red if: a valid SID is rejected.
func TestUnknownSIDValidPasses(t *testing.T) {
	s, _ := guardServer(func(string) (string, error) { return "ryan", nil })
	got, err := s.validateUnknownSID(fromIP("10.8.0.3", "/x"), "good")
	if err != nil || got != "ryan" {
		t.Fatalf("got (%q, %v), want ryan", got, err)
	}
}

// Red if: one address can send unlimited distinct unknown SIDs at DSM.
func TestUnknownSIDPerIPLimit(t *testing.T) {
	var calls atomic.Int32
	s, _ := guardServer(func(string) (string, error) { calls.Add(1); return "", errDSMSessionInvalid })
	limited := 0
	for i := 0; i < sidValidationPerIPMax+10; i++ {
		_, err := s.validateUnknownSID(fromIP("10.8.0.4", "/x"), fmt.Sprintf("sid-%d", i))
		if errors.Is(err, errSIDRateLimited) {
			limited++
		}
	}
	if int(calls.Load()) != sidValidationPerIPMax || limited != 10 {
		t.Fatalf("DSM calls=%d limited=%d, want %d and 10", calls.Load(), limited, sidValidationPerIPMax)
	}
	if _, err := s.validateUnknownSID(fromIP("10.8.0.5", "/x"), "other"); errors.Is(err, errSIDRateLimited) {
		t.Fatal("second address limited by first's traffic")
	}
}

// Red if: more than sidValidationInflight validations run at once, or overflow does not fail closed.
func TestUnknownSIDConcurrencyCapFailsClosed(t *testing.T) {
	release := make(chan struct{})
	var inflight, peak atomic.Int32
	s, _ := guardServer(func(string) (string, error) {
		n := inflight.Add(1)
		for {
			p := peak.Load()
			if n <= p || peak.CompareAndSwap(p, n) {
				break
			}
		}
		<-release
		inflight.Add(-1)
		return "ryan", nil
	})
	var wg sync.WaitGroup
	for i := 0; i < sidValidationInflight; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, _ = s.validateUnknownSID(fromIP(fmt.Sprintf("10.7.0.%d", i+1), "/x"), fmt.Sprintf("sid-%d", i))
		}(i)
	}
	deadline := time.Now().Add(2 * time.Second)
	for int(inflight.Load()) < sidValidationInflight && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if int(inflight.Load()) != sidValidationInflight {
		close(release)
		wg.Wait()
		t.Fatalf("only %d validations in flight", inflight.Load())
	}
	_, err := s.validateUnknownSID(fromIP("10.7.1.1", "/x"), "one-too-many")
	close(release)
	wg.Wait()
	if !errors.Is(err, errSIDValidationBusy) {
		t.Fatalf("overflow err = %v, want errSIDValidationBusy", err)
	}
	if int(peak.Load()) > sidValidationInflight {
		t.Fatalf("peak in flight %d exceeds cap %d", peak.Load(), sidValidationInflight)
	}
}

// Red if: an over-long SID costs a DSM call, or the negative cache outgrows its cap.
func TestUnknownSIDLengthAndCacheCap(t *testing.T) {
	var calls atomic.Int32
	s, g := guardServer(func(string) (string, error) { calls.Add(1); return "", errDSMSessionInvalid })
	long := strings.Repeat("a", sidMaxLen+1)
	if _, err := s.validateUnknownSID(fromIP("10.6.0.1", "/x"), long); err == nil || calls.Load() != 0 {
		t.Fatalf("long SID: err=%v calls=%d", err, calls.Load())
	}
	for i := 0; i < sidNegativeCacheMax+500; i++ {
		var k [32]byte
		k[0], k[1], k[2] = byte(i), byte(i>>8), byte(i>>16)
		g.cacheNegative(k)
	}
	g.mu.Lock()
	n := len(g.negative)
	g.mu.Unlock()
	if n > sidNegativeCacheMax {
		t.Fatalf("negative cache holds %d, cap %d", n, sidNegativeCacheMax)
	}
}

// ---- P2-4: pairing failures counted per code and per IP ----

func failN(s *Server, ip string, n int) {
	for i := 0; i < n; i++ {
		s.pairingMu.Lock()
		s.recordPairingFailureLocked(ip, time.Now())
		s.pairingMu.Unlock()
	}
}

func hasCode(s *Server, code string) bool {
	s.pairingMu.Lock()
	defer s.pairingMu.Unlock()
	_, ok := s.pairingCodes[code]
	return ok
}

// Red if: one address sending wrong codes revokes someone else's code (the old global lockout).
func TestPairingOneAttackerCannotRevokeOthersCodes(t *testing.T) {
	s := pairingTestServer()
	code := generateCode(t, s, "")
	failN(s, "10.5.0.66", 500)
	if !hasCode(s, code) {
		t.Fatal("one address revoked a code")
	}
	decodeExchange(t, exchange(s, code, "10.5.0.1"))
}

// Red if: an address keeps being served past its wrong-code budget.
func TestPairingAddressLockedOutAfterItsBudget(t *testing.T) {
	s := pairingTestServer()
	code := generateCode(t, s, "")
	wrong := fmt.Sprintf("%06d", (mustAtoi(t, code)+1)%1_000_000)
	for i := 0; i < pairingIPMaxFailures; i++ {
		if w := exchange(s, wrong, "10.5.1.1"); w.Code != http.StatusUnauthorized {
			t.Fatalf("wrong code %d: status %d, want 401", i+1, w.Code)
		}
	}
	if w := exchange(s, code, "10.5.1.1"); w.Code != http.StatusTooManyRequests {
		t.Fatalf("locked-out address: status %d, want 429", w.Code)
	}
	if w := exchange(s, code, "10.5.1.2"); w.Code != http.StatusOK {
		t.Fatalf("other address: status %d, want 200", w.Code)
	}
}

// Red if: an address adds more than its cap to one code, or distinct addresses cannot revoke it.
func TestPairingCodeRevokedOnlyByEnoughDistinctAddresses(t *testing.T) {
	s := pairingTestServer()
	victim := generateCode(t, s, "")
	needed := pairingMaxFailures / pairingPerIPCodeFailureCap
	for a := 0; a < needed-1; a++ {
		failN(s, fmt.Sprintf("10.4.0.%d", a), pairingPerIPCodeFailureCap)
	}
	failN(s, "10.4.0.0", 50) // past its cap: adds nothing
	if !hasCode(s, victim) {
		t.Fatalf("code revoked by %d addresses / an address past its cap", needed-1)
	}
	failN(s, fmt.Sprintf("10.4.0.%d", needed), pairingPerIPCodeFailureCap)
	if hasCode(s, victim) {
		t.Fatalf("code survived guesses from %d distinct addresses", needed)
	}
}

// Red if: a fresh code inherits an earlier code's failure count.
func TestPairingFailuresAreCountedPerCode(t *testing.T) {
	s := pairingTestServer()
	first := generateCode(t, s, "")
	for a := 0; a < pairingMaxFailures/pairingPerIPCodeFailureCap; a++ {
		failN(s, fmt.Sprintf("10.3.9.%d", a), pairingPerIPCodeFailureCap)
	}
	if hasCode(s, first) {
		t.Fatal("first code should be revoked")
	}
	fresh := generateCode(t, s, "")
	s.pairingMu.Lock()
	e := s.pairingCodes[fresh]
	s.pairingMu.Unlock()
	if e.failures != 0 {
		t.Fatalf("fresh code starts with %d failures", e.failures)
	}
}

// Red if: the per-address table grows past its cap or is never swept.
func TestPairingIPTableIsBoundedAndSwept(t *testing.T) {
	s := pairingTestServer()
	generateCode(t, s, "")
	now := time.Now()
	s.pairingMu.Lock()
	for i := 0; i < pairingIPTrackerMax+500; i++ {
		s.recordPairingFailureLocked(fmt.Sprintf("ip-%d", i), now)
	}
	n := len(s.pairingIPFailures)
	s.sweepPairingIPFailuresLocked(now.Add(pairingIPWindow + time.Second))
	after := len(s.pairingIPFailures)
	s.pairingMu.Unlock()
	if n > pairingIPTrackerMax {
		t.Fatalf("table holds %d, cap %d", n, pairingIPTrackerMax)
	}
	if after != 0 {
		t.Fatalf("%d entries survived the sweep", after)
	}
}

// ---- P2-5: didToLoginBinding swept and size-capped ----

func resetBindings() {
	didToLoginBinding.Range(func(k, _ any) bool { didToLoginBinding.Delete(k); return true })
}

// Red if: stale bindings stay forever, or fresh ones are swept.
func TestLoginBindingsAreSwept(t *testing.T) {
	resetBindings()
	defer resetBindings()
	now := time.Now()
	didToLoginBinding.Store("old", loginBinding{Username: "a", CreatedAt: now.Add(-loginBindingTTL - time.Second)})
	didToLoginBinding.Store("new", loginBinding{Username: "b", CreatedAt: now})
	(&Server{}).sweepSecurityState(now)
	if _, ok := didToLoginBinding.Load("old"); ok {
		t.Error("expired binding survived the sweep")
	}
	if _, ok := didToLoginBinding.Load("new"); !ok {
		t.Error("fresh binding was swept")
	}
}

// Red if: the table outgrows its cap, or a full table evicts a live binding.
func TestLoginBindingsAreCapped(t *testing.T) {
	resetBindings()
	defer resetBindings()
	now := time.Now()
	for i := 0; i < loginBindingMax; i++ {
		if !storeLoginBinding(fmt.Sprintf("d%d", i), "u", now) {
			t.Fatalf("binding %d refused below the cap", i)
		}
	}
	if storeLoginBinding("overflow", "u", now) {
		t.Fatal("binding stored past the cap")
	}
	if _, ok := didToLoginBinding.Load("d0"); !ok {
		t.Fatal("a live binding was evicted to make room")
	}
	if !storeLoginBinding("later", "u", now.Add(loginBindingTTL+time.Second)) {
		t.Fatal("expired entries were not reclaimed at the cap")
	}
}

// ---- P3-2: EvalSymlinks before the media-root check ----

// Red if: a symlink inside the library that points outside it is served.
func TestPathWithinMediaRootRejectsSymlinkEscape(t *testing.T) {
	root, outside := t.TempDir(), t.TempDir()
	if err := os.WriteFile(filepath.Join(outside, "secret.mkv"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	s := serverWithRoots(root, "", "")
	if err := osSymlink(outside, filepath.Join(root, "escape")); err != nil {
		t.Skipf("symlink unsupported: %v", err)
	}
	if err := osSymlink(filepath.Join(outside, "secret.mkv"), filepath.Join(root, "file-link.mkv")); err != nil {
		t.Skipf("symlink unsupported: %v", err)
	}
	for _, p := range []string{
		filepath.Join(root, "escape", "secret.mkv"),
		filepath.Join(root, "escape", "not-yet-created.srt"),
		filepath.Join(root, "file-link.mkv"),
	} {
		if s.pathWithinMediaRoot(p) {
			t.Errorf("%q resolves outside the media root but was accepted", p)
		}
	}
}

// Red if: a dangling symlink (target unverifiable) is accepted.
func TestPathWithinMediaRootRejectsDanglingSymlink(t *testing.T) {
	root := t.TempDir()
	s := serverWithRoots(root, "", "")
	if err := osSymlink("/nonexistent/elsewhere", filepath.Join(root, "dangling")); err != nil {
		t.Skipf("symlink unsupported: %v", err)
	}
	if s.pathWithinMediaRoot(filepath.Join(root, "dangling")) {
		t.Error("dangling symlink accepted")
	}
}

// Red if: legitimate layouts break (in-root symlink, symlinked root, not-yet-created file).
func TestPathWithinMediaRootStillAcceptsLegitimatePaths(t *testing.T) {
	base := t.TempDir()
	real := filepath.Join(base, "real")
	if err := os.MkdirAll(filepath.Join(real, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(real, "sub", "a.mkv"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	linkedRoot := filepath.Join(base, "linked-root")
	if err := osSymlink(real, linkedRoot); err != nil {
		t.Skipf("symlink unsupported: %v", err)
	}
	if err := osSymlink(filepath.Join(real, "sub"), filepath.Join(real, "alias")); err != nil {
		t.Skipf("symlink unsupported: %v", err)
	}
	s := serverWithRoots(linkedRoot, "", "")
	for _, p := range []string{
		filepath.Join(linkedRoot, "sub", "a.mkv"),
		filepath.Join(real, "sub", "a.mkv"),
		filepath.Join(real, "alias", "a.mkv"),
		filepath.Join(linkedRoot, "sub", "new.srt"),
	} {
		if !s.pathWithinMediaRoot(p) {
			t.Errorf("%q is inside the media root but was rejected", p)
		}
	}
}

// ---- P3-3: no first-user-is-admin fallback ----

// Red if: with no admin configured and no owner recorded a caller becomes admin or an owner row is written.
func TestNoFirstUserAdminFallback(t *testing.T) {
	s, _ := newProfilesTestServer(t)
	s.cfg.AdminUser = ""
	if s.isAdmin(authedUser{Username: "first"}) || s.isAdmin(authedUser{Username: "second"}) {
		t.Fatal("a caller became admin with no admin configured")
	}
	if got := s.ownerUsername(); got != "" {
		t.Fatalf("owner %q was recorded by calling isAdmin", got)
	}
}

// Red if: an owner recorded by an earlier version stops being honoured, or the configured admin stops winning.
func TestRecordedOwnerAndConfiguredAdminStillWork(t *testing.T) {
	s, db := newProfilesTestServer(t)
	s.cfg.AdminUser = ""
	if _, err := db.Exec(`INSERT INTO settings(key, user_id, value, updated_at) VALUES('owner_username','','ryan','2026-01-01T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	if !s.isAdmin(authedUser{Username: "Ryan"}) || s.isAdmin(authedUser{Username: "mallory"}) {
		t.Fatal("recorded owner not honoured")
	}
	s.cfg.AdminUser = "boss"
	if !s.isAdmin(authedUser{Username: "boss"}) || s.isAdmin(authedUser{Username: "ryan"}) {
		t.Fatal("configured admin must take precedence over the recorded owner")
	}
}

// ---- Non-loopback request counter ----

// Red if: a direct peer is not counted, a loopback peer is, or a spoofed X-Real-IP hides a direct hit.
func TestNonLoopbackCounter(t *testing.T) {
	c := newPeerCounter(time.Now())
	h := c.middleware(trustedRealIP(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {})))
	do := func(peer, realIP string) {
		r := httptest.NewRequest(http.MethodGet, "/x", nil)
		r.RemoteAddr = peer + ":4000"
		if realIP != "" {
			r.Header.Set("X-Real-IP", realIP)
		}
		h.ServeHTTP(httptest.NewRecorder(), r)
	}
	do("127.0.0.1", "203.0.113.9")
	do("[::1]", "")
	if got := c.nonLoopback.Load(); got != 0 {
		t.Fatalf("loopback peers counted: %d", got)
	}
	do("198.51.100.7", "127.0.0.1")
	do("10.0.0.5", "")
	if got := c.nonLoopback.Load(); got != 2 {
		t.Fatalf("count = %d, want 2", got)
	}
	if d := c.logDelta(); d != 2 {
		t.Fatalf("daily delta %d, want 2", d)
	}
	if d := c.logDelta(); d != 0 {
		t.Fatalf("second delta %d, want 0", d)
	}
}
