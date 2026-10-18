package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// TASK-972 · pairing must leave a first-time device able to reach the server (FR-117).

func pairingTestServer() *Server {
	return &Server{pairingCodes: make(map[string]pairingEntry), cfg: Config{JWTSecret: "pairing-test-secret"}}
}

// generateCode asks for a code as user u1 with the given body and returns it.
func generateCode(t *testing.T, s *Server, body string) string {
	t.Helper()
	w := httptest.NewRecorder()
	s.handlePairingGenerate(w, authedRequest(http.MethodPost, "/api/v1/auth/pairing/generate", body, "u1", "ryan", ""))
	if w.Code != http.StatusOK {
		t.Fatalf("generate: status %d, body %s", w.Code, w.Body.String())
	}
	var resp struct {
		Code string `json:"code"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil || len(resp.Code) != 6 {
		t.Fatalf("generate: bad response %q (%v)", w.Body.String(), err)
	}
	return resp.Code
}

// exchange redeems code from ip and returns the recorder.
func exchange(s *Server, code, ip string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(http.MethodPost, "/api/v1/auth/pairing/exchange", strings.NewReader(`{"code":"`+code+`"}`))
	r.RemoteAddr = ip + ":51000"
	w := httptest.NewRecorder()
	s.handlePairingExchange(w, r)
	return w
}

type exchangeBody struct {
	Token string `json:"token"`
	User  struct {
		ID string `json:"id"`
	} `json:"user"`
	Server *struct {
		QuickConnectID string `json:"quickConnectId"`
		LANAddress     string `json:"lanAddress"`
		WANAddress     string `json:"wanAddress"`
	} `json:"server"`
}

func decodeExchange(t *testing.T, w *httptest.ResponseRecorder) exchangeBody {
	t.Helper()
	if w.Code != http.StatusOK {
		t.Fatalf("exchange: status %d, body %s", w.Code, w.Body.String())
	}
	var b exchangeBody
	if err := json.Unmarshal(w.Body.Bytes(), &b); err != nil {
		t.Fatalf("exchange: %v (%s)", err, w.Body.String())
	}
	return b
}

// Red if: the exchange answers token+user only, so a device that found the server on its LAN
// has no way to reach it from anywhere else.
func TestPairingExchangeReturnsTheGeneratorsConnection(t *testing.T) {
	s := pairingTestServer()
	code := generateCode(t, s, `{"quickConnectId":"ryans-nas","lanAddress":"http://192.168.50.148:8090","wanAddress":"nas.example.org:8091"}`)

	b := decodeExchange(t, exchange(s, code, "10.1.0.1"))
	if b.Token == "" || b.User.ID != "u1" {
		t.Fatalf("exchange did not sign in as the generating account: %+v", b)
	}
	if b.Server == nil {
		t.Fatal("exchange carried no server object")
	}
	if b.Server.QuickConnectID != "ryans-nas" || b.Server.LANAddress != "http://192.168.50.148:8090" || b.Server.WANAddress != "nas.example.org:8091" {
		t.Fatalf("server object = %+v", *b.Server)
	}
}

// An already-shipped client sends generate with no body (or JSON null). It must keep working,
// and its exchange simply carries no server object.
func TestPairingGenerateWithNoBodyStillPairs(t *testing.T) {
	for _, body := range []string{"", "null", "  "} {
		s := pairingTestServer()
		code := generateCode(t, s, body)
		b := decodeExchange(t, exchange(s, code, "10.1.0.2"))
		if b.Token == "" {
			t.Fatalf("body %q: no token", body)
		}
		if b.Server != nil {
			t.Fatalf("body %q: server object %+v for a code generated with no details", body, *b.Server)
		}
	}
}

func TestPairingGenerateRejectsMalformedJSON(t *testing.T) {
	s := pairingTestServer()
	w := httptest.NewRecorder()
	s.handlePairingGenerate(w, authedRequest(http.MethodPost, "/api/v1/auth/pairing/generate", `{"lanAddress":`, "u1", "ryan", ""))
	if w.Code != http.StatusBadRequest {
		t.Fatalf("malformed body: status %d, want 400", w.Code)
	}
	if len(s.pairingCodes) != 0 {
		t.Fatal("a code was stored for a rejected request")
	}
}

// Connection fields are user-controlled input handed to another device: anything that is not
// a plain address is dropped, and the code still pairs.
func TestPairingDropsConnectionFieldsThatAreNotAddresses(t *testing.T) {
	cases := []struct{ field, value string }{
		{"quickConnectId", "bad id!"},
		{"quickConnectId", strings.Repeat("a", 65)},
		{"lanAddress", "http://user:pw@192.168.1.5:8090"},
		{"lanAddress", "ftp://192.168.1.5"},
		{"lanAddress", "192.168.1.5 8090"},
		{"wanAddress", "https://nas.example.org/?next=evil"},
		{"wanAddress", "https://nas.example.org/#frag"},
		{"wanAddress", strings.Repeat("a", 256) + ".org"},
		{"wanAddress", "nas.exämple.org"},
		{"wanAddress", "http://"},
	}
	for _, c := range cases {
		s := pairingTestServer()
		body, _ := json.Marshal(map[string]string{c.field: c.value})
		code := generateCode(t, s, string(body))
		b := decodeExchange(t, exchange(s, code, "10.1.0.3"))
		if b.Token == "" {
			t.Fatalf("%s=%q: the code did not pair", c.field, c.value)
		}
		if b.Server != nil {
			t.Fatalf("%s=%q was handed on: %+v", c.field, c.value, *b.Server)
		}
	}

	// And the valid shapes survive.
	for _, addr := range []string{"192.168.1.5", "192.168.1.5:8090", "http://192.168.1.5:8090", "https://nas.example.org:8091/dsvideo", "nas.local"} {
		if !validPairingAddress(addr) {
			t.Errorf("valid address %q rejected", addr)
		}
	}
}

// Red if: a redeemed code can be redeemed again.
func TestPairingCodeIsSingleUse(t *testing.T) {
	s := pairingTestServer()
	code := generateCode(t, s, "")
	decodeExchange(t, exchange(s, code, "10.1.0.4"))
	if w := exchange(s, code, "10.1.0.5"); w.Code != http.StatusUnauthorized {
		t.Fatalf("second exchange of the same code: status %d, want 401", w.Code)
	}
}

// Red if: an expired code is honoured.
func TestPairingCodeExpires(t *testing.T) {
	s := pairingTestServer()
	code := generateCode(t, s, "")
	s.pairingMu.Lock()
	e := s.pairingCodes[code]
	e.expiresAt = time.Now().Add(-time.Second)
	s.pairingCodes[code] = e
	s.pairingMu.Unlock()
	if w := exchange(s, code, "10.1.0.6"); w.Code != http.StatusUnauthorized {
		t.Fatalf("expired code: status %d, want 401", w.Code)
	}
}

// Red if: wrong guesses spread across many addresses can keep guessing a live code forever.
// After 20 wrong codes (from any address) every outstanding code is revoked; 19 are tolerated.
func TestPairingWrongCodesRevokeOutstandingCodes(t *testing.T) {
	s := pairingTestServer()
	code := generateCode(t, s, "")
	wrong := fmt.Sprintf("%06d", (mustAtoi(t, code)+1)%1_000_000)

	for i := 1; i <= 19; i++ {
		if w := exchange(s, wrong, fmt.Sprintf("10.2.0.%d", i)); w.Code != http.StatusUnauthorized {
			t.Fatalf("wrong code %d: status %d, want 401", i, w.Code)
		}
	}
	s.pairingMu.Lock()
	_, stillLive := s.pairingCodes[code]
	s.pairingMu.Unlock()
	if !stillLive {
		t.Fatal("the real code was revoked after only 19 wrong codes")
	}

	exchange(s, wrong, "10.2.0.20")
	if w := exchange(s, code, "10.2.0.21"); w.Code != http.StatusUnauthorized {
		t.Fatalf("the real code still redeems after 20 wrong codes: status %d", w.Code)
	}

	// A fresh code afterwards works: the count started again.
	fresh := generateCode(t, s, "")
	decodeExchange(t, exchange(s, fresh, "10.2.0.22"))
}

// Wrong codes with nothing outstanding are not banked against the next code.
func TestPairingWrongCodesWithNoLiveCodeAreNotCounted(t *testing.T) {
	s := pairingTestServer()
	for i := 1; i <= 25; i++ {
		exchange(s, "000000", fmt.Sprintf("10.3.0.%d", i))
	}
	code := generateCode(t, s, "")
	decodeExchange(t, exchange(s, code, "10.3.1.1"))
}

// FR-144: a code or a token in the log is a session for whoever reads it.
func TestPairingNeverLogsCodesOrTokens(t *testing.T) {
	buf := captureStdLog(t)
	s := pairingTestServer()
	code := generateCode(t, s, `{"lanAddress":"bad address","quickConnectId":"ryans-nas"}`)
	b := decodeExchange(t, exchange(s, code, "10.4.0.1"))
	exchange(s, code, "10.4.0.2")
	logged := buf.String()
	if strings.Contains(logged, code) {
		t.Fatalf("the pairing code appears in the log:\n%s", logged)
	}
	if strings.Contains(logged, b.Token) {
		t.Fatalf("the session token appears in the log:\n%s", logged)
	}
	if strings.Contains(logged, "bad address") {
		t.Fatalf("a rejected field's value appears in the log:\n%s", logged)
	}
}

func mustAtoi(t *testing.T, s string) int {
	t.Helper()
	var n int
	if _, err := fmt.Sscanf(s, "%d", &n); err != nil {
		t.Fatal(err)
	}
	return n
}
