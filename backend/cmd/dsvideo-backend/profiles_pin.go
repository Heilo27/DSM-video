package main

// FRD-002 §3: profile PIN hashing (FR-214) and the per-profile failure limiter (FR-215).
// A PIN is never logged, stored in clear, or returned; only its hash touches the database.

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"math"
	"strconv"
	"strings"
	"sync"
	"time"
)

// entropy is where profile IDs and PIN salts get their randomness. A variable only so a test
// can make the source fail: the failure paths it guards answer `server_error`, which must
// leave a log line (TASK-1048).
var entropy io.Reader = rand.Reader

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
	if _, err := io.ReadFull(entropy, salt); err != nil {
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

// pinLimiter counts consecutive PIN failures per profile id. Every PIN-accepting endpoint
// for a profile shares its entry; owner-PIN checks on management calls use the owner
// profile's id.
//
// State is persisted in profile_pin_lockouts (TASK-932 SEC-7) so a package restart does
// not hand an attacker a fresh failure budget or reset the lockout escalation. Memory is a
// cache: an entry loads its row on first use and writes it back after every change; a row
// exists only while a profile has failures or lockouts outstanding. With no database
// (tests that build &Server{}), the limiter is memory-only.
//
// Each entry has its own mutex, held for the whole check-verify-record sequence, so
// concurrent guesses against one profile are serialized and cannot overshoot the 5-failure
// budget, while unrelated profiles never contend.
type pinLimiter struct {
	mu      sync.Mutex
	now     func() time.Time
	db      *sql.DB
	entries map[string]*pinEntry
}

type pinEntry struct {
	mu          sync.Mutex
	loaded      bool      // the persisted row has been read into this entry
	dropped     bool      // reset removed this entry from the map; callers must re-fetch
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

// migratePinLockouts creates the persisted limiter state. Additive: a new table, nothing
// existing touched. locked_until_ms is Unix milliseconds, 0 when not locked.
func migratePinLockouts(db *sql.DB) error {
	_, err := db.Exec(`
CREATE TABLE IF NOT EXISTS profile_pin_lockouts (
  profile_id TEXT PRIMARY KEY,
  failures INTEGER NOT NULL DEFAULT 0,
  lockouts INTEGER NOT NULL DEFAULT 0,
  locked_until_ms INTEGER NOT NULL DEFAULT 0
);`)
	if err != nil {
		return fmt.Errorf("create profile_pin_lockouts: %w", err)
	}
	return nil
}

// newPinLimiter returns a limiter persisting to db, or memory-only when db is nil.
func newPinLimiter(now func() time.Time, db *sql.DB) *pinLimiter {
	if now == nil {
		now = time.Now
	}
	return &pinLimiter{now: now, db: db, entries: make(map[string]*pinEntry)}
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

// lockedEntry returns id's entry with its mutex held and its persisted state loaded.
func (l *pinLimiter) lockedEntry(id string) (*pinEntry, func() time.Time) {
	for {
		e, nowFn := l.entry(id)
		e.mu.Lock()
		if e.dropped { // reset raced us; its replacement is in the map
			e.mu.Unlock()
			continue
		}
		if !e.loaded {
			e.loaded = l.load(id, e)
		}
		return e, nowFn
	}
}

// load reads id's persisted state into e (caller holds e.mu). A read failure is logged
// and reported as not loaded, so the next attempt retries; until then the in-memory
// count still applies.
func (l *pinLimiter) load(id string, e *pinEntry) bool {
	if l.db == nil {
		return true
	}
	var failures, lockouts int
	var untilMs int64
	err := l.db.QueryRow(
		`SELECT failures, lockouts, locked_until_ms FROM profile_pin_lockouts WHERE profile_id = ?`, id,
	).Scan(&failures, &lockouts, &untilMs)
	switch {
	case err == sql.ErrNoRows:
		return true
	case err != nil:
		log.Printf("[pin] lockout state for profile %s not loaded: %v", id, err)
		return false
	}
	// Persisted state only ever adds to what this process has counted since the entry
	// was created (normally nothing).
	e.failures = max(e.failures, failures)
	e.lockouts = max(e.lockouts, lockouts)
	if untilMs > 0 {
		if t := time.UnixMilli(untilMs); t.After(e.lockedUntil) {
			e.lockedUntil = t
		}
	}
	return true
}

// persist writes e's state for id (caller holds e.mu): the row is deleted when nothing is
// outstanding. A write failure is logged; the in-memory state still applies.
func (l *pinLimiter) persist(id string, e *pinEntry) {
	if l.db == nil {
		return
	}
	var err error
	if e.failures == 0 && e.lockouts == 0 && e.lockedUntil.IsZero() {
		_, err = l.db.Exec(`DELETE FROM profile_pin_lockouts WHERE profile_id = ?`, id)
	} else {
		var untilMs int64
		if !e.lockedUntil.IsZero() {
			untilMs = e.lockedUntil.UnixMilli()
		}
		_, err = l.db.Exec(`
INSERT INTO profile_pin_lockouts (profile_id, failures, lockouts, locked_until_ms) VALUES (?, ?, ?, ?)
ON CONFLICT(profile_id) DO UPDATE SET failures = excluded.failures, lockouts = excluded.lockouts,
  locked_until_ms = excluded.locked_until_ms`,
			id, e.failures, e.lockouts, untilMs)
	}
	if err != nil {
		log.Printf("[pin] lockout state for profile %s not persisted: %v", id, err)
	}
}

// attempt runs verify for profile id unless it is locked out, and records the outcome.
// While locked, verify is not called at all: even a correct PIN is refused (AC-002-19).
func (l *pinLimiter) attempt(id string, verify func() bool) pinResult {
	e, nowFn := l.lockedEntry(id)
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
		hadState := e.failures != 0 || e.lockouts != 0 || !e.lockedUntil.IsZero()
		e.failures, e.lockouts, e.lockedUntil = 0, 0, time.Time{}
		if hadState {
			l.persist(id, e)
		}
		return pinResult{OK: true}
	}
	e.failures++
	if e.failures < pinMaxFailures {
		l.persist(id, e)
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
	l.persist(id, e)
	return pinResult{AttemptsRemaining: 0}
}

// reset forgets a profile's failures and lockouts, in memory and on disk: its PIN was
// set, changed or cleared, or the profile was deleted. It holds the limiter mutex
// throughout (lock order: l.mu, then an entry's mu; attempt never takes them the other way
// round), so an attempt already holding the old entry finishes before the row is deleted
// and cannot write it back, and no new entry can load the row before it is gone.
func (l *pinLimiter) reset(id string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	e, ok := l.entries[id]
	if !ok {
		e = &pinEntry{}
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	delete(l.entries, id)
	e.dropped = true
	e.failures, e.lockouts, e.lockedUntil = 0, 0, time.Time{}
	l.persist(id, e)
}
