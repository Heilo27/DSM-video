package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
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

// Independent QA of TASK-1082 (Worf). Written against the FRD / ACs, not the implementer's
// tests. Each test names the code change that turns it red.
//
// Tests prefixed TestQA1082Repro_ reproduce DEFECTS found in review (red on commit 3835114,
// fixed after): they assert the CORRECT behaviour and now always run.

// chain wires the production order: peer counter, then trustedRealIP, then the handler.
func chain(s *Server, h http.HandlerFunc) http.Handler {
	return s.peers.middleware(trustedRealIP(h))
}

func qaReq(peer string, hdr map[string]string) *http.Request {
	r := httptest.NewRequest(http.MethodGet, "/webapi/auth.cgi", nil)
	r.RemoteAddr = peer
	for k, v := range hdr {
		r.Header.Set(k, v)
	}
	return r
}

func limiterHandler(s *Server, bucket string, max int) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if s.rateLimitExceeded(r, bucket, max, time.Minute) {
			w.WriteHeader(http.StatusTooManyRequests)
			return
		}
		w.WriteHeader(http.StatusOK)
	}
}

// ---- item 1: forwarded headers are honoured ONLY from a loopback peer ----

// Red if: trustedRealIP trusts X-Forwarded-For / X-Real-IP from a non-loopback peer, so
// rotating the header gives a fresh bucket on every request.
func TestQA1082_SpoofedForwardedHeadersFromNonLoopbackPeerDoNotShiftBucket(t *testing.T) {
	s := &Server{peers: newPeerCounter(time.Now())}
	h := chain(s, limiterHandler(s, "qa-spoof", 3))
	const peer = "203.0.113.9:40000"

	for i := 1; i <= 3; i++ {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, qaReq(peer, nil))
		if w.Code != http.StatusOK {
			t.Fatalf("request %d inside budget got %d", i, w.Code)
		}
	}
	spoofs := []map[string]string{
		{"X-Forwarded-For": "198.51.100.1"},
		{"X-Forwarded-For": "198.51.100.2, 198.51.100.3"},
		{"X-Forwarded-For": "127.0.0.1"},
		{"X-Real-IP": "198.51.100.4"},
		{"X-Real-IP": "::1"},
		{"X-Real-IP": "198.51.100.5", "X-Forwarded-For": "198.51.100.6"},
		{"True-Client-IP": "198.51.100.7"},
		{"X-Forwarded-For": "not-an-ip"},
	}
	for i, hdr := range spoofs {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, qaReq(peer, hdr))
		if w.Code != http.StatusTooManyRequests {
			t.Errorf("spoof #%d %v: got %d, want 429 (bucket must stay keyed on the TCP peer)", i, hdr, w.Code)
		}
	}
	// A different real peer is a different bucket (the limiter is per IP, not global).
	w := httptest.NewRecorder()
	h.ServeHTTP(w, qaReq("203.0.113.10:40000", nil))
	if w.Code != http.StatusOK {
		t.Errorf("an unrelated peer was limited by the first peer's traffic: %d", w.Code)
	}
}

// Red if: an IPv6 / v4-mapped non-loopback peer is mistaken for loopback, or an IPv6
// loopback peer is not recognised (nginx on ::1 must still be trusted).
func TestQA1082_PeerLoopbackClassification(t *testing.T) {
	cases := []struct {
		remote   string
		loopback bool
	}{
		{"127.0.0.1:1", true},
		{"[::1]:1", true},
		{"127.0.0.2:1", true},
		{"[::ffff:127.0.0.1]:1", true},
		{"192.168.1.20:1", false},
		{"203.0.113.9:1", false},
		{"[2001:db8::1]:1", false},
		{"[::ffff:192.168.1.20]:1", false},
		{"[fe80::1%en0]:1", false},
		{"", false},
		{"garbage", false},
	}
	for _, c := range cases {
		if got := peerIsLoopback(c.remote); got != c.loopback {
			t.Errorf("peerIsLoopback(%q) = %v, want %v", c.remote, got, c.loopback)
		}
	}
}

// Red if: the packaged nginx path (loopback peer + X-Real-IP / XFF) stops giving each real
// client its own bucket, so one noisy client would throttle the whole household.
func TestQA1082_LoopbackPeerGivesEachForwardedClientItsOwnBucket(t *testing.T) {
	s := &Server{peers: newPeerCounter(time.Now())}
	h := chain(s, limiterHandler(s, "qa-nginx", 2))
	noisy := map[string]string{"X-Real-IP": "192.168.1.50", "X-Forwarded-For": "6.6.6.6, 192.168.1.50"}
	quiet := map[string]string{"X-Real-IP": "192.168.1.51", "X-Forwarded-For": "192.168.1.51"}
	for i := 0; i < 5; i++ {
		h.ServeHTTP(httptest.NewRecorder(), qaReq("127.0.0.1:50000", noisy))
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, qaReq("127.0.0.1:50001", noisy))
	if w.Code != http.StatusTooManyRequests {
		t.Errorf("noisy client was not limited: %d", w.Code)
	}
	w = httptest.NewRecorder()
	h.ServeHTTP(w, qaReq("127.0.0.1:50002", quiet))
	if w.Code != http.StatusOK {
		t.Errorf("quiet client behind the same nginx was limited by the noisy one: %d", w.Code)
	}
	// XFF-only (no X-Real-IP): the LAST entry is the one nginx vouched for; a client-supplied
	// first entry must not pick the bucket.
	h2 := chain(s, limiterHandler(s, "qa-xff-last", 1))
	for i := 0; i < 3; i++ {
		w = httptest.NewRecorder()
		h2.ServeHTTP(w, qaReq("127.0.0.1:50003", map[string]string{"X-Forwarded-For": fmt.Sprintf("10.9.9.%d, 192.168.1.60", i)}))
		if i == 0 && w.Code != http.StatusOK {
			t.Fatalf("first request limited: %d", w.Code)
		}
		if i > 0 && w.Code != http.StatusTooManyRequests {
			t.Errorf("request %d with a rotated FIRST xff entry got %d, want 429 (last entry is the key)", i, w.Code)
		}
	}
}

// ---- item 8: nonLoopbackRequests end to end ----

func adminStatusCount(t *testing.T, h http.Handler, peer string, hdr map[string]string) (count int64, since string) {
	t.Helper()
	w := httptest.NewRecorder()
	h.ServeHTTP(w, qaReq(peer, hdr))
	if w.Code != http.StatusOK {
		t.Fatalf("admin status %d: %s", w.Code, w.Body.String())
	}
	var body struct {
		OK     bool `json:"ok"`
		NonLoo struct {
			Count int64  `json:"count"`
			Since string `json:"since"`
		} `json:"nonLoopbackRequests"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v (%s)", err, w.Body.String())
	}
	if !body.OK {
		t.Fatalf("not ok: %s", w.Body.String())
	}
	return body.NonLoo.Count, body.NonLoo.Since
}

// Red if: loopback traffic (IPv4, IPv6, nginx with forwarded headers) is counted, a direct
// LAN/WAN peer is not counted, a loopback-claiming header from a remote peer defeats the
// count, or the counter reads the REWRITTEN RemoteAddr (middleware order) instead of the raw peer.
func TestQA1082_NonLoopbackRequestsCountedEndToEndInAdminStatus(t *testing.T) {
	s := &Server{peers: newPeerCounter(time.Now())}
	h := chain(s, s.handleAdminStatus)

	// Probe itself arrives over loopback so it never moves the count.
	if n, since := adminStatusCount(t, h, "127.0.0.1:50000", nil); n != 0 || since == "" {
		t.Fatalf("fresh counter: count=%d since=%q, want 0 and a timestamp", n, since)
	}
	// nginx traffic: loopback peers, with and without forwarded headers.
	for _, p := range []string{"127.0.0.1:1", "[::1]:2"} {
		adminStatusCount(t, h, p, map[string]string{"X-Real-IP": "192.168.1.77", "X-Forwarded-For": "192.168.1.77"})
	}
	if n, _ := adminStatusCount(t, h, "127.0.0.1:3", nil); n != 0 {
		t.Fatalf("loopback traffic counted: %d, want 0", n)
	}
	// Direct hits around nginx: LAN, WAN, IPv6 WAN, and one forging a loopback XFF/X-Real-IP.
	adminStatusCount(t, h, "192.168.1.50:5000", nil)
	adminStatusCount(t, h, "203.0.113.9:5000", map[string]string{"X-Forwarded-For": "127.0.0.1", "X-Real-IP": "127.0.0.1"})
	adminStatusCount(t, h, "[2001:db8::7]:5000", nil)
	// The probe below is itself the 4th direct hit; the response is built after the middleware ran.
	if n, _ := adminStatusCount(t, h, "198.51.100.1:5000", nil); n != 4 {
		t.Fatalf("count = %d, want 4 (LAN, WAN-with-forged-XFF, IPv6 WAN, and this probe)", n)
	}
	// And a loopback probe now reads 4 without adding to it.
	if n, _ := adminStatusCount(t, h, "127.0.0.1:9", nil); n != 4 {
		t.Fatalf("loopback probe moved the count: %d, want 4", n)
	}
}

// Red if: logDelta reports the running total instead of the delta since the last log, or the
// daily goroutine never logs / does not stop on context cancel.
func TestQA1082_PeerCounterDailyLogReportsDeltaAndStops(t *testing.T) {
	c := newPeerCounter(time.Now())
	var buf syncBuffer
	prev := log.Writer()
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(prev) })

	h := c.middleware(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	hit := func(peer string, n int) {
		for i := 0; i < n; i++ {
			h.ServeHTTP(httptest.NewRecorder(), qaReq(peer, nil))
		}
	}
	hit("192.168.1.9:1", 3)
	hit("127.0.0.1:1", 5)
	if d := c.logDelta(); d != 3 {
		t.Fatalf("first delta = %d, want 3", d)
	}
	hit("203.0.113.1:1", 2)
	if d := c.logDelta(); d != 2 {
		t.Fatalf("second delta = %d, want 2 (not the running total 5)", d)
	}
	if d := c.logDelta(); d != 0 {
		t.Fatalf("idle delta = %d, want 0", d)
	}

	ctx, cancel := context.WithCancel(context.Background())
	hit("203.0.113.1:1", 7)
	done := make(chan struct{})
	go func() { c.runDailyLog(ctx, 10*time.Millisecond); close(done) }()
	deadline := time.Now().Add(2 * time.Second)
	for !strings.Contains(buf.String(), "non-loopback requests in the last 24h: 7 ") && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("runDailyLog did not stop on context cancel")
	}
	if !strings.Contains(buf.String(), "non-loopback requests in the last 24h: 7 ") {
		t.Fatalf("daily log never reported the delta of 7; log:\n%s", buf.String())
	}
	if strings.Contains(buf.String(), "203.0.113") || strings.Contains(buf.String(), "192.168.1.9") {
		t.Error("the daily log leaked a peer address; the counter must count only")
	}
}

type syncBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}
func (s *syncBuffer) String() string { s.mu.Lock(); defer s.mu.Unlock(); return s.b.String() }

// ---- items 1/10: legit traffic at normal rates never hits the limiters ----

// Red if: a normal DS Video session (a screenful of meta calls, a few logins) trips a budget.
func TestQA1082_NormalClientRatesStayUnderEveryDSMLimiter(t *testing.T) {
	s := &Server{}
	// 10 info/encryption/Auth.Type calls per second for 10 s is far above any real app.
	for i := 0; i < dsmMetaPassthroughMax; i++ {
		if s.dsmMetaPassthroughLimited(httptest.NewRecorder(), fromIP("10.20.0.1", "/webapi/entry.cgi")) {
			t.Fatalf("meta call %d limited; budget %d/min", i+1, dsmMetaPassthroughMax)
		}
	}
	for i := 0; i < dsmAuthPassthroughMax; i++ {
		if s.dsmAuthPassthroughLimited(httptest.NewRecorder(), fromIP("10.20.0.1", "/webapi/auth.cgi")) {
			t.Fatalf("auth call %d limited; budget %d/min", i+1, dsmAuthPassthroughMax)
		}
	}
	if dsmAuthPassthroughMax < 20 || dsmMetaPassthroughMax < 60 {
		t.Errorf("budgets (%d auth, %d meta per min) leave no headroom for an app launch burst", dsmAuthPassthroughMax, dsmMetaPassthroughMax)
	}
}

// ---- item 2: unknown _sid, through getWebAPISession (the real caller) ----

func sidServer(t *testing.T, validate func(string) (string, error)) *Server {
	t.Helper()
	s, _ := newProfilesTestServer(t)
	s.cfg.JWTSecret = "qa-1082-secret"
	g := s.sidGuardFor()
	g.validate = validate
	return s
}

func sidRequest(sid, ip, ua string) *http.Request {
	r := httptest.NewRequest(http.MethodGet, "/webapi/entry.cgi?api=SYNO.VideoStation2.Movie&_sid="+sid, nil)
	r.Header.Set("User-Agent", ua)
	r.RemoteAddr = ip + ":50000"
	return r
}

func dropSID(sid string) {
	webAPISessions.mu.Lock()
	delete(webAPISessions.sessions, sid)
	webAPISessions.mu.Unlock()
}

// Red if: a DSM transport failure / timeout yields a session (fail OPEN), or it is cached so
// the same SID is denied for a minute after DSM recovers.
func TestQA1082_UnknownSIDFailsClosedOnDSMErrorAndRecovers(t *testing.T) {
	var down atomic.Bool
	down.Store(true)
	var calls atomic.Int32
	s := sidServer(t, func(string) (string, error) {
		calls.Add(1)
		if down.Load() {
			return "", context.DeadlineExceeded
		}
		return "ryan", nil
	})
	const sid = "qa-sid-failclosed-0001"
	defer dropSID(sid)
	for i := 0; i < 3; i++ {
		if got := s.getWebAPISession(sidRequest(sid, "10.30.0.1", "DS video/3.1.0 (iOS)")); got != nil {
			t.Fatalf("attempt %d: DSM unreachable but a session was granted", i)
		}
	}
	if webAPISessions.Get(sid) != nil {
		t.Fatal("a denied SID was stored as a session")
	}
	down.Store(false)
	got := s.getWebAPISession(sidRequest(sid, "10.30.0.1", "curl/8"))
	if got == nil || got.Username != "ryan" {
		t.Fatalf("after DSM recovered the valid SID was still denied: %+v (transport errors must not be cached)", got)
	}
	if calls.Load() != 4 {
		t.Errorf("DSM asked %d times, want 4", calls.Load())
	}
}

// Red if: DSM's definitive "invalid" is not cached (every replay costs a DSM call), or an
// empty-account success is accepted as a session.
func TestQA1082_UnknownSIDInvalidIsCachedAndEmptyAccountDenied(t *testing.T) {
	var calls atomic.Int32
	s := sidServer(t, func(sid string) (string, error) {
		calls.Add(1)
		if strings.HasSuffix(sid, "-empty") {
			return "", nil
		}
		return "", errDSMSessionInvalid
	})
	for _, sid := range []string{"qa-sid-bad-0002", "qa-sid-bad-0003-empty"} {
		for i := 0; i < 6; i++ {
			if s.getWebAPISession(sidRequest(sid, "10.30.0.2", "DS video/3.1.0")) != nil {
				t.Fatalf("%s: granted a session", sid)
			}
		}
	}
	if calls.Load() != 2 {
		t.Fatalf("DSM asked %d times for 12 replays of 2 SIDs, want 2", calls.Load())
	}
}

// Red if: DSVIDEO_ALLOW_UNVALIDATED_DSVIDEO still has any effect (a DS Video UA is granted a
// session without DSM vouching for it).
func TestQA1082_RemovedUnvalidatedEnvVarHasNoEffect(t *testing.T) {
	for _, v := range []string{"1", "true", "yes", "on"} {
		t.Setenv("DSVIDEO_ALLOW_UNVALIDATED_DSVIDEO", v)
		s := sidServer(t, func(string) (string, error) { return "", errDSMSessionInvalid })
		sid := "qa-sid-env-" + v
		if got := s.getWebAPISession(sidRequest(sid, "10.30.0.3", "DS video/3.1.0 (iOS)")); got != nil {
			dropSID(sid)
			t.Fatalf("env=%q: DS Video UA with an invalid SID got a session", v)
		}
		s2 := sidServer(t, func(string) (string, error) { return "", errors.New("dsm down") })
		if got := s2.getWebAPISession(sidRequest(sid+"b", "10.30.0.3", "DS video/3.1.0 (iOS)")); got != nil {
			dropSID(sid + "b")
			t.Fatalf("env=%q: DS Video UA with DSM down got a session (fail open)", v)
		}
	}
}

// Red if: the stored-session fast path starts spending the unknown-SID budget (a household
// of known devices would then be throttled) or a known SID stops being served.
func TestQA1082_KnownSIDsNeverTouchTheUnknownSIDGuard(t *testing.T) {
	var calls atomic.Int32
	s := sidServer(t, func(string) (string, error) { calls.Add(1); return "ryan", nil })
	const sid = "qa-sid-known-0004"
	defer dropSID(sid)
	if s.getWebAPISession(sidRequest(sid, "10.30.0.4", "curl/8")) == nil {
		t.Fatal("first (validated) request denied")
	}
	for i := 0; i < sidValidationPerIPMax*3; i++ {
		if s.getWebAPISession(sidRequest(sid, "10.30.0.4", "curl/8")) == nil {
			t.Fatalf("known SID denied on request %d", i)
		}
	}
	if calls.Load() != 1 {
		t.Errorf("DSM asked %d times for one SID, want 1", calls.Load())
	}
}

// DEFECT (Major, availability): a legitimate burst of more than sidValidationInflight
// concurrent requests carrying the SAME valid, not-yet-stored SID is partly denied. Every
// request in the burst runs its own validation (no coalescing), so the 9th..Nth concurrent
// request hits the semaphore and is told "no session" although the SID is valid.
// Real trigger: the official DS Video app logs in on DSM's own port, then fans out a screenful
// of poster/metadata requests at our port with a SID we have never seen.
func TestQA1082Repro_ValidSIDBurstIsNotDenied(t *testing.T) {
	s := sidServer(t, func(string) (string, error) {
		time.Sleep(150 * time.Millisecond) // a plausible DSM auth.cgi round trip under load
		return "ryan", nil
	})
	const sid = "qa-sid-burst-0005"
	defer dropSID(sid)
	const burst = 24
	var denied atomic.Int32
	var wg sync.WaitGroup
	start := make(chan struct{})
	for i := 0; i < burst; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			if s.getWebAPISession(sidRequest(sid, "10.30.0.5", "curl/8")) == nil {
				denied.Add(1)
			}
		}()
	}
	close(start)
	wg.Wait()
	if denied.Load() != 0 {
		t.Fatalf("%d of %d concurrent requests with one VALID sid were denied", denied.Load(), burst)
	}
}

// ---- item 3: pairing, through the handlers ----

// Red if: one address's wrong guesses lock out or revoke a legitimate code redeemed from
// another address (the pre-1082 global 20-strike revoke-all), or the code's own counter runs
// past the per-address cap.
func TestQA1082_PairingAttackerCannotLockOutVictimFromAnotherIP(t *testing.T) {
	s := pairingTestServer()
	victim := generateCode(t, s, "")
	wrong := fmt.Sprintf("%06d", (mustAtoi(t, victim)+1)%1_000_000)

	var statuses []int
	for i := 0; i < 40; i++ {
		w := exchange(s, wrong, "198.51.100.66")
		statuses = append(statuses, w.Code)
		if w.Code == http.StatusTooManyRequests && w.Header().Get("Retry-After") == "" {
			t.Fatal("429 without Retry-After")
		}
	}
	if statuses[0] != http.StatusUnauthorized {
		t.Fatalf("first wrong guess = %d, want 401", statuses[0])
	}
	if statuses[len(statuses)-1] != http.StatusTooManyRequests {
		t.Fatalf("attacker never throttled: %v", statuses)
	}
	s.pairingMu.Lock()
	e, alive := s.pairingCodes[victim]
	s.pairingMu.Unlock()
	if !alive {
		t.Fatal("one attacking address revoked the victim's code (old global lockout)")
	}
	if e.failures > pairingPerIPCodeFailureCap {
		t.Fatalf("one address added %d failures to a code, cap %d", e.failures, pairingPerIPCodeFailureCap)
	}
	body := decodeExchange(t, exchange(s, victim, "192.0.2.10"))
	if body.Token == "" || body.User.ID != "u1" {
		t.Fatalf("victim from another IP did not get a token for u1: %+v", body)
	}
	// One-shot: the code cannot be redeemed twice.
	if w := exchange(s, victim, "192.0.2.11"); w.Code != http.StatusUnauthorized {
		t.Fatalf("second redemption = %d, want 401", w.Code)
	}
}

// ---- item 4: didToLoginBinding sweep and cap ----

func clearBindings() {
	didToLoginBinding.Range(func(k, _ any) bool { didToLoginBinding.Delete(k); return true })
}

// Red if: the table can grow past the cap, expired entries are not swept, a live entry is
// evicted to make room, or the cap sweep does not free room for a legitimate login.
func TestQA1082_LoginBindingCapSweepAndNoEviction(t *testing.T) {
	clearBindings()
	t.Cleanup(clearBindings)
	now := time.Now()
	for i := 0; i < loginBindingMax; i++ {
		if !storeLoginBinding(fmt.Sprintf("did-%d", i), "ryan", now) {
			t.Fatalf("binding %d refused below the cap", i)
		}
	}
	if n := loginBindingCount(); n != loginBindingMax {
		t.Fatalf("count = %d, want %d", n, loginBindingMax)
	}
	if storeLoginBinding("did-overflow", "ryan", now) {
		t.Fatal("binding accepted at the cap with every entry live")
	}
	if n := loginBindingCount(); n != loginBindingMax {
		t.Fatalf("count after refusal = %d, want %d", n, loginBindingMax)
	}
	if _, ok := didToLoginBinding.Load("did-0"); !ok {
		t.Fatal("a live binding was evicted")
	}
	if _, ok := didToLoginBinding.Load("did-overflow"); ok {
		t.Fatal("refused binding was stored anyway")
	}
	later := now.Add(loginBindingTTL + time.Second)
	if !storeLoginBinding("did-after-expiry", "ryan", later) {
		t.Fatal("expired entries did not make room")
	}
	if n := loginBindingCount(); n != 1 {
		t.Fatalf("count after sweep = %d, want 1 (only the new binding)", n)
	}
}

// ---- item 6: symlink containment ----

func mkdirs(t *testing.T, paths ...string) {
	t.Helper()
	for _, p := range paths {
		if err := os.MkdirAll(p, 0o755); err != nil {
			t.Fatal(err)
		}
	}
}

func writeFile(t *testing.T, p, body string) {
	t.Helper()
	mkdirs(t, filepath.Dir(p))
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func realTemp(t *testing.T) string {
	t.Helper()
	d, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return d
}

// Red if: any of the symlink cases flips: a link leaving the root is followed as if inside,
// a link staying inside is refused, a dangling link is allowed, a chained link escapes, a
// link into a prefix-sibling passes, or a configured root that is ITSELF a symlink (common on
// a NAS) locks every file out.
func TestQA1082_SymlinkContainmentMatrix(t *testing.T) {
	base := realTemp(t)
	root := filepath.Join(base, "Movies")
	sibling := filepath.Join(base, "Movies2") // string-prefix sibling of root
	outside := filepath.Join(base, "private")
	mkdirs(t, root, sibling, outside)
	writeFile(t, filepath.Join(root, "Heat.mkv"), "x")
	writeFile(t, filepath.Join(root, "real", "a.mkv"), "x")
	writeFile(t, filepath.Join(outside, "secret.txt"), "TOPSECRET")
	writeFile(t, filepath.Join(sibling, "other.mkv"), "x")

	link := func(target, name string) string {
		p := filepath.Join(root, name)
		if err := os.Symlink(target, p); err != nil {
			t.Fatal(err)
		}
		return p
	}
	inIn := link(filepath.Join(root, "real"), "alias")
	out := link(outside, "escape")
	fileOut := link(filepath.Join(outside, "secret.txt"), "leak.mkv")
	dangling := link(filepath.Join(base, "nowhere"), "dead")
	hop2 := link(outside, "hop2")
	hop1 := link(hop2, "hop1")
	toSibling := link(sibling, "sib")

	rootAsLink := filepath.Join(base, "MoviesLink")
	if err := os.Symlink(root, rootAsLink); err != nil {
		t.Fatal(err)
	}

	s := serverWithRoots(root, "", "")
	sLinkRoot := serverWithRoots(rootAsLink, "", "")

	cases := []struct {
		name string
		s    *Server
		path string
		want bool
	}{
		{"plain existing file", s, filepath.Join(root, "Heat.mkv"), true},
		{"plain missing sidecar (embedded_subs/sprite output)", s, filepath.Join(root, "Heat.en.srt"), true},
		{"missing sidecar in a missing dir", s, filepath.Join(root, "newdir", "deep", "x.srt"), true},
		{"link inside to inside, existing file", s, filepath.Join(inIn, "a.mkv"), true},
		{"link inside to inside, missing file", s, filepath.Join(inIn, "new.srt"), true},
		{"link inside to inside, the link itself", s, inIn, true},
		{"dir link out, existing file", s, filepath.Join(out, "secret.txt"), false},
		{"dir link out, missing file under it", s, filepath.Join(out, "new.srt"), false},
		{"dir link out, the link itself", s, out, false},
		{"file link out", s, fileOut, false},
		{"dangling link", s, dangling, false},
		{"missing file under dangling link", s, filepath.Join(dangling, "x.srt"), false},
		{"two-hop chain out", s, filepath.Join(hop1, "secret.txt"), false},
		{"link into string-prefix sibling", s, filepath.Join(toSibling, "other.mkv"), false},
		{"sibling directly", s, filepath.Join(sibling, "other.mkv"), false},
		{"outside directly", s, filepath.Join(outside, "secret.txt"), false},
		{"root itself", s, root, true},
		{"empty path", s, "", false},
		{"configured root is a symlink: file via the link path", sLinkRoot, filepath.Join(rootAsLink, "Heat.mkv"), true},
		{"configured root is a symlink: file via the real path", sLinkRoot, filepath.Join(root, "Heat.mkv"), true},
		{"configured root is a symlink: escape inside it", sLinkRoot, filepath.Join(rootAsLink, "escape", "secret.txt"), false},
	}
	for _, c := range cases {
		if got := c.s.pathWithinMediaRoot(c.path); got != c.want {
			t.Errorf("%s: pathWithinMediaRoot(%q) = %v, want %v", c.name, c.path, got, c.want)
		}
	}
}

// Red if: the production callers (playback, embedded_subs) lose access to ordinary files
// because the containment check now errors on them.
func TestQA1082_EmbeddedSubsStillAcceptsNormalFileAndRefusesEscape(t *testing.T) {
	base := realTemp(t)
	root := filepath.Join(base, "Shows")
	outside := filepath.Join(base, "private")
	mkdirs(t, root, outside)
	writeFile(t, filepath.Join(root, "S01E01.mkv"), "x")
	writeFile(t, filepath.Join(outside, "evil.mkv"), "x")
	if err := os.Symlink(outside, filepath.Join(root, "escape")); err != nil {
		t.Fatal(err)
	}
	s := serverWithRoots("", root, "")
	s.cfg.FFmpegPath = "/nonexistent/ffmpeg" // non-empty so the guard is reached; never executed on refusal
	s.cfg.TranscodeDir = t.TempDir()

	var buf syncBuffer
	prev := log.Writer()
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(prev) })

	if tracks := s.collectEmbeddedSubtitles("item-esc", filepath.Join(root, "escape", "evil.mkv"), 0, nil); tracks != nil {
		t.Fatalf("escape path returned tracks: %v", tracks)
	}
	if !strings.Contains(buf.String(), "not within any media root") {
		t.Fatalf("escape path was not refused by the media-root guard; log:\n%s", buf.String())
	}
	buf.mu.Lock()
	buf.b.Reset()
	buf.mu.Unlock()
	_ = s.collectEmbeddedSubtitles("item-ok", filepath.Join(root, "S01E01.mkv"), 0, nil)
	if strings.Contains(buf.String(), "not within any media root") {
		t.Fatalf("a normal file under the root was refused; log:\n%s", buf.String())
	}
}

// DEFECT (Major, security): resolveSymlinksAllowMissing lexically Cleans the path BEFORE
// resolving symlinks. "root/link/../secret" cleans to "root/secret" (inside the root), but the
// kernel resolves "link" first, so the same string opened by os.Stat / ffmpeg lands in
// <link target>/../secret, outside the root. handlePlayback (main.go:3897) and the other
// callers hand the RAW path to os.Stat / ffmpeg, not the cleaned one, so the guard approves
// a path the OS reads from outside the library. Needs a tampered items.path row plus a
// symlink inside the root, the same preconditions as the symlink escape this task closes.
func TestQA1082Repro_DotDotAfterSymlinkCannotEscapeTheRoot(t *testing.T) {
	base := realTemp(t)
	root := filepath.Join(base, "Movies")
	outside := filepath.Join(base, "private")
	mkdirs(t, root, filepath.Join(outside, "sub"))
	writeFile(t, filepath.Join(outside, "secret.txt"), "TOPSECRET")
	if err := os.Symlink(filepath.Join(outside, "sub"), filepath.Join(root, "link")); err != nil {
		t.Fatal(err)
	}
	raw := filepath.Join(root, "link") + string(filepath.Separator) + ".." + string(filepath.Separator) + "secret.txt"

	// Ground truth: the OS really opens the file outside the root through this string.
	// (filepath.Join would Clean it away, so the raw string is built by hand.)
	data, err := os.ReadFile(raw)
	if err != nil || string(data) != "TOPSECRET" {
		t.Fatalf("precondition: the raw path should read the outside file, got %q, %v", data, err)
	}
	s := serverWithRoots(root, "", "")
	if s.pathWithinMediaRoot(raw) {
		t.Fatalf("pathWithinMediaRoot approved %q, which the OS resolves to %s (outside the root)", raw, filepath.Join(outside, "secret.txt"))
	}
}

// ---- item 7: admin ----

// Red if: a first-user fallback returns (an unconfigured, unowned install makes the first
// caller admin or writes an owner row), an install with a recorded owner loses admin, or the
// owner match becomes case-sensitive.
func TestQA1082_AdminHasNoFirstUserFallbackButHonoursRecordedOwner(t *testing.T) {
	s, db := newProfilesTestServer(t)
	count := func() int {
		var n int
		if err := db.QueryRow(`SELECT COUNT(*) FROM settings WHERE key = 'owner_username'`).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	before := count()
	if s.isAdmin(authedUser{ID: "u1", Username: "ryan"}) || s.isAdmin(authedUser{ID: "u2", Username: "alice"}) {
		t.Fatal("no admin configured and no owner recorded, but someone is admin")
	}
	if s.isAdmin(authedUser{}) {
		t.Fatal("empty username is admin")
	}
	if count() != before {
		t.Fatalf("isAdmin wrote an owner row (%d -> %d)", before, count())
	}

	if _, err := db.Exec(`INSERT INTO settings (key, user_id, value, updated_at) VALUES ('owner_username', '', 'ryan', '2026-01-01T00:00:00Z')`); err != nil {
		t.Fatalf("seed owner (as the live NAS has it): %v", err)
	}
	if !s.isAdmin(authedUser{ID: "u1", Username: "ryan"}) || !s.isAdmin(authedUser{ID: "u1", Username: "Ryan"}) {
		t.Fatal("recorded owner lost admin (live NAS has owner_username=ryan)")
	}
	if s.isAdmin(authedUser{ID: "u2", Username: "alice"}) || s.isAdmin(authedUser{ID: "u3", Username: "ryan2"}) {
		t.Fatal("a non-owner is admin")
	}
	if count() != 1 {
		t.Fatalf("owner rows = %d, want exactly the seeded 1", count())
	}

	s.cfg.AdminUser = "alice"
	if s.isAdmin(authedUser{ID: "u1", Username: "ryan"}) || !s.isAdmin(authedUser{ID: "u2", Username: "ALICE"}) {
		t.Fatal("a configured DSVIDEO_ADMIN_USER must override the recorded owner")
	}
}
