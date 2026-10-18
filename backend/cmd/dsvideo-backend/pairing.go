package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

// TASK-972 · a pairing code carries the way to reach this server (FRD-001 FR-117).
//
// A device that has never connected knows no server address, so it cannot be told one by
// this server until it has already found it. Pairing therefore works in two halves:
//
//  1. The signed-in device sends its own connection details (QuickConnect ID, LAN and WAN
//     address) when it asks for a code. The server cannot know its WAN address or
//     QuickConnect ID itself; the device that reached it can.
//  2. The new device finds this server on its local network (Bonjour, `_dsvideo._tcp`),
//     redeems the code there, and the exchange hands back those details so it can still
//     reach the server once it leaves home.

const (
	// pairingMaxFailures is how many wrong codes, from any address, revoke every outstanding
	// code. The per-IP auth limiter (10/min) alone lets a caller with many addresses walk the
	// 1,000,000-code space; this caps the guesses a single generated code can face, the same
	// role the per-profile failure count plays for PINs (profiles_pin.go). A legitimate user
	// mistyping a code a few times never gets near it; the cost of hitting it is generating a
	// new code.
	pairingMaxFailures = 20

	// pairingAddressMaxLen bounds every connection field. A hostname is at most 253 bytes.
	pairingAddressMaxLen = 255

	// pairingGenerateMaxBody bounds the generate request body.
	pairingGenerateMaxBody = 4 << 10
)

// quickConnectIDPattern is what Synology accepts as a QuickConnect ID: letters, digits,
// hyphens (underscores tolerated, as the clients do).
var quickConnectIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`)

// pairingServerInfo is how the device that generated a code reaches this server. Every field
// is optional; an older client sends none.
type pairingServerInfo struct {
	QuickConnectID string `json:"quickConnectId,omitempty"`
	LANAddress     string `json:"lanAddress,omitempty"`
	WANAddress     string `json:"wanAddress,omitempty"`
}

func (p pairingServerInfo) isEmpty() bool {
	return p.QuickConnectID == "" && p.LANAddress == "" && p.WANAddress == ""
}

// sanitized returns p with every field that fails validation cleared, plus the names of the
// cleared fields (names only: the values are never logged). A bad field is dropped rather
// than failing the request: the code still pairs, the new device just learns less.
func (p pairingServerInfo) sanitized() (pairingServerInfo, []string) {
	var dropped []string
	if p.QuickConnectID != "" && !quickConnectIDPattern.MatchString(p.QuickConnectID) {
		p.QuickConnectID = ""
		dropped = append(dropped, "quickConnectId")
	}
	if p.LANAddress != "" && !validPairingAddress(p.LANAddress) {
		p.LANAddress = ""
		dropped = append(dropped, "lanAddress")
	}
	if p.WANAddress != "" && !validPairingAddress(p.WANAddress) {
		p.WANAddress = ""
		dropped = append(dropped, "wanAddress")
	}
	return p, dropped
}

// validPairingAddress accepts "host", "host:port" or an http(s) URL with an optional path.
// It refuses anything that could carry more than an address: embedded credentials, a query
// or fragment, whitespace, control or non-ASCII characters.
func validPairingAddress(s string) bool {
	if s == "" || len(s) > pairingAddressMaxLen {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] <= ' ' || s[i] >= 0x7f {
			return false
		}
	}
	raw := s
	if !strings.Contains(s, "://") {
		raw = "http://" + s
	}
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") {
		return false
	}
	return u.Hostname() != "" && u.User == nil && u.RawQuery == "" && u.Fragment == "" && !u.ForceQuery
}

// decodePairingGenerateBody reads the optional connection details from a generate request.
// An empty body (or JSON null) is an older client and yields no details; malformed JSON is
// an error.
func decodePairingGenerateBody(w http.ResponseWriter, r *http.Request) (pairingServerInfo, error) {
	var info pairingServerInfo
	if r.Body == nil {
		return info, nil
	}
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, pairingGenerateMaxBody))
	if err != nil {
		return info, err
	}
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 || bytes.Equal(raw, []byte("null")) {
		return info, nil
	}
	if err := json.Unmarshal(raw, &info); err != nil {
		return pairingServerInfo{}, err
	}
	return info, nil
}

// hasLivePairingCodeLocked reports whether any code could still be redeemed. Caller holds
// pairingMu.
func (s *Server) hasLivePairingCodeLocked(now time.Time) bool {
	for _, e := range s.pairingCodes {
		if !e.exchanged && now.Before(e.expiresAt) {
			return true
		}
	}
	return false
}

// recordPairingFailureLocked counts one wrong code while at least one live code exists (with
// none, there is nothing to guess at). On reaching pairingMaxFailures every outstanding code
// is revoked and the count starts again; it returns how many live codes were revoked, or -1
// if the budget was not reached. Caller holds pairingMu.
func (s *Server) recordPairingFailureLocked(now time.Time) int {
	if !s.hasLivePairingCodeLocked(now) {
		return -1
	}
	s.pairingFailures++
	if s.pairingFailures < pairingMaxFailures {
		return -1
	}
	revoked := 0
	for code, e := range s.pairingCodes {
		if !e.exchanged && now.Before(e.expiresAt) {
			revoked++
		}
		delete(s.pairingCodes, code)
	}
	s.pairingFailures = 0
	return revoked
}
