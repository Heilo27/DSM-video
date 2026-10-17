package main

// FRD-002 §3: profile PIN hashing (FR-214) and the per-profile failure limiter (FR-215).
// A PIN is never logged, stored in clear, or returned; only its hash touches the database.

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"math"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	// pinHashIterations: PBKDF2-HMAC-SHA256 cost. 100k iterations is tens of milliseconds on
	// the NAS's low-end CPUs, well under FR-214's one-second ceiling, and makes an offline
	// sweep of the 10,000-PIN space cost real time per guess. Stored in each hash, so it can
	// be raised later without invalidating existing PINs.
	pinHashIterations = 100000
	pinSaltBytes      = 16
	pinKeyBytes       = 32
	pinHashScheme     = "pbkdf2-sha256"
	// maxStoredIterations bounds what verifyPIN will honour from a stored string, so a
	// corrupted row cannot turn one PIN check into a CPU-bound hang.
	maxStoredIterations = 10_000_000
)

// validPINFormat is FR-210: exactly 4 ASCII digits ("0420", never 420 or "٠٤٢٠").
func validPINFormat(pin string) bool {
	if len(pin) != 4 {
		return false
	}
	for i := 0; i < len(pin); i++ {
		if pin[i] < '0' || pin[i] > '9' {
			return false
		}
	}
	return true
}

// pbkdf2SHA256 is RFC 8018 PBKDF2 with HMAC-SHA256. Hand-rolled because go.mod pins go 1.22
// and crypto/pbkdf2 arrived in 1.24. One HMAC instance is reused with Reset; Sum appends
// into a reused buffer so the inner loop does not allocate.
func pbkdf2SHA256(password, salt []byte, iterations, keyLen int) []byte {
	prf := hmac.New(sha256.New, password)
	hLen := prf.Size()
	blocks := (keyLen + hLen - 1) / hLen
	out := make([]byte, 0, blocks*hLen)
	var idx [4]byte
	u := make([]byte, 0, hLen)
	t := make([]byte, hLen)
	for block := 1; block <= blocks; block++ {
		binary.BigEndian.PutUint32(idx[:], uint32(block))
		prf.Reset()
		prf.Write(salt)
		prf.Write(idx[:])
		u = prf.Sum(u[:0])
		copy(t, u)
		for n := 1; n < iterations; n++ {
			prf.Reset()
			prf.Write(u)
			u = prf.Sum(u[:0])
			for i := range t {
				t[i] ^= u[i]
			}
		}
		out = append(out, t...)
	}
	return out[:keyLen]
}

// hashPIN returns "pbkdf2-sha256$<iterations>$<b64 salt>$<b64 key>" (RawStdEncoding).
func hashPIN(pin string) (string, error) {
	salt := make([]byte, pinSaltBytes)
	if _, err := rand.Read(salt); err != nil {
		return "", fmt.Errorf("pin salt: %w", err)
	}
	key := pbkdf2SHA256([]byte(pin), salt, pinHashIterations, pinKeyBytes)
	enc := base64.RawStdEncoding
	return pinHashScheme + "$" + strconv.Itoa(pinHashIterations) + "$" +
		enc.EncodeToString(salt) + "$" + enc.EncodeToString(key), nil
}

// verifyPIN checks pin against a stored hash in constant time. A malformed stored value
// never matches.
func verifyPIN(stored, pin string) bool {
	parts := strings.Split(stored, "$")
	if len(parts) != 4 || parts[0] != pinHashScheme {
		return false
	}
	iter, err := strconv.Atoi(parts[1])
	if err != nil || iter < 1 || iter > maxStoredIterations {
		return false
	}
	enc := base64.RawStdEncoding
	salt, err := enc.DecodeString(parts[2])
	if err != nil || len(salt) == 0 {
		return false
	}
	want, err := enc.DecodeString(parts[3])
	if err != nil || len(want) == 0 {
		return false
	}
	got := pbkdf2SHA256([]byte(pin), salt, iter, len(want))
	return subtle.ConstantTimeCompare(got, want) == 1
}

// ── Limiter (FR-215) ────────────────────────────────────────────────────────────────────

const (
	pinMaxFailures = 5
	pinBaseLockout = 300 * time.Second
	pinMaxLockout  = 3600 * time.Second
)

// pinLimiter counts consecutive PIN failures per profile id, in memory (a restart resetting
// it is acceptable, FR-215). Every PIN-accepting endpoint for a profile shares its entry;
// owner-PIN checks on management calls use the owner profile's id.
//
// Each entry has its own mutex, held for the whole check-verify-record sequence, so
// concurrent guesses against one profile are serialized and cannot overshoot the 5-failure
// budget, while unrelated profiles never contend.
type pinLimiter struct {
	mu      sync.Mutex
	now     func() time.Time
	entries map[string]*pinEntry
}

type pinEntry struct {
	mu          sync.Mutex
	failures    int       // consecutive failures since the last success or lockout
	lockouts    int       // lockouts since the last success; each doubles the wait
	lockedUntil time.Time // zero when not locked
}

type pinResult struct {
	OK                bool
	Locked            bool
	RetryAfterSeconds int // set when Locked
	AttemptsRemaining int // set on a wrong PIN; 0 means this failure started a lockout
}

func newPinLimiter(now func() time.Time) *pinLimiter {
	if now == nil {
		now = time.Now
	}
	return &pinLimiter{now: now, entries: make(map[string]*pinEntry)}
}

func (l *pinLimiter) setNow(now func() time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if now == nil {
		now = time.Now
	}
	l.now = now
}

func (l *pinLimiter) entry(id string) (*pinEntry, func() time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	e, ok := l.entries[id]
	if !ok {
		e = &pinEntry{}
		l.entries[id] = e
	}
	return e, l.now
}

// attempt runs verify for profile id unless it is locked out, and records the outcome.
// While locked, verify is not called at all: even a correct PIN is refused (AC-002-19).
func (l *pinLimiter) attempt(id string, verify func() bool) pinResult {
	e, nowFn := l.entry(id)
	e.mu.Lock()
	defer e.mu.Unlock()

	now := nowFn()
	if now.Before(e.lockedUntil) {
		secs := int(math.Ceil(e.lockedUntil.Sub(now).Seconds()))
		if secs < 1 {
			secs = 1
		}
		return pinResult{Locked: true, RetryAfterSeconds: secs}
	}
	if verify() {
		e.failures, e.lockouts, e.lockedUntil = 0, 0, time.Time{}
		return pinResult{OK: true}
	}
	e.failures++
	if e.failures < pinMaxFailures {
		return pinResult{AttemptsRemaining: pinMaxFailures - e.failures}
	}
	// The 5th wrong answer is itself reported as pin_incorrect with 0 remaining and starts
	// the lock; the next attempt gets pin_locked.
	wait := pinBaseLockout
	for i := 0; i < e.lockouts && wait < pinMaxLockout; i++ {
		wait *= 2
	}
	if wait > pinMaxLockout {
		wait = pinMaxLockout
	}
	e.lockouts++
	e.failures = 0
	e.lockedUntil = now.Add(wait)
	return pinResult{AttemptsRemaining: 0}
}

// reset forgets a profile's failures and lockouts: its PIN was set, changed or cleared,
// or the profile was deleted.
func (l *pinLimiter) reset(id string) {
	l.mu.Lock()
	delete(l.entries, id)
	l.mu.Unlock()
}
