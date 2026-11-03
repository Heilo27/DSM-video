package main

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"log"
	"net/http"
	"sync"
	"time"
)

// Unknown-SID validation guard (TASK-1082 P1-3).
//
// A request carrying a SID we do not hold costs one POST to DSM's auth.cgi. Anyone who can
// reach the port can send those at will, so each one is bounded three ways before it may
// reach DSM:
//
//   - a per-client-IP budget (the one rateLimitExceeded limiter, bucket "sidval");
//   - a negative cache: a SID DSM has just called invalid is not asked about again for
//     sidNegativeTTL, however many times it is replayed;
//   - a concurrency cap on in-flight validations, so a flood from many addresses cannot pin
//     DSM's auth endpoint. When the cap is full the request fails closed (no session).
//
// Only a definitive "DSM says invalid" is cached; a transport failure is not, so a DSM
// hiccup never locks out a valid SID.
const (
	rateLimitBucketSIDValidation = "sidval"
	sidValidationPerIPMax        = 30
	sidValidationWindow          = time.Minute

	sidNegativeTTL        = 60 * time.Second
	sidNegativeCacheMax   = 4096
	sidValidationInflight = 8
	sidMaxLen             = 256 // a real DSM SID is ~64 chars; longer is never worth a DSM call
)

var (
	// errDSMSessionInvalid is DSM's definitive answer that the SID is not a live session (or
	// has no account). Distinct from transport/decode errors, which say nothing about the SID.
	errDSMSessionInvalid = errors.New("DSM session invalid or account missing")

	errSIDRejected       = errors.New("sid rejected without DSM call")
	errSIDRateLimited    = errors.New("sid validation rate-limited")
	errSIDValidationBusy = errors.New("sid validation busy")
)

// sidFlight is one in-flight DSM validation. Every concurrent request carrying the same SID
// waits on done and shares account/err; they are written once, before done closes.
type sidFlight struct {
	done    chan struct{}
	account string
	err     error
}

type sidValidationGuard struct {
	mu       sync.Mutex
	flight   map[[sha256.Size]byte]*sidFlight // in-flight DSM validations by sha256(sid); see validateUnknownSID
	negative map[[sha256.Size]byte]time.Time  // sha256(sid) -> expiry; the SID itself is never kept
	sem      chan struct{}

	// Seams for tests; production values are set by sidGuardFor.
	now      func() time.Time
	validate func(sid string) (string, error)
}

// sidGuardFor returns the server's guard, creating it on first use. Lazy because tests build
// Server literals.
func (s *Server) sidGuardFor() *sidValidationGuard {
	s.sidGuardOnce.Do(func() {
		s.sidGuard = &sidValidationGuard{
			negative: make(map[[sha256.Size]byte]time.Time),
			flight:   make(map[[sha256.Size]byte]*sidFlight),
			sem:      make(chan struct{}, sidValidationInflight),
			now:      time.Now,
			validate: s.validateDSMSession,
		}
	})
	return s.sidGuard
}

func (g *sidValidationGuard) negativeHit(key [sha256.Size]byte) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	exp, ok := g.negative[key]
	if !ok {
		return false
	}
	if !g.now().Before(exp) {
		delete(g.negative, key)
		return false
	}
	return true
}

func (g *sidValidationGuard) cacheNegative(key [sha256.Size]byte) {
	g.mu.Lock()
	defer g.mu.Unlock()
	now := g.now()
	if len(g.negative) >= sidNegativeCacheMax {
		g.sweepLocked(now)
	}
	if len(g.negative) >= sidNegativeCacheMax {
		// Still full of live entries. Not caching is safe (the per-IP and concurrency limits
		// still bound DSM calls); evicting arbitrary live entries would let an attacker flush
		// the cache on purpose.
		return
	}
	g.negative[key] = now.Add(sidNegativeTTL)
}

func (g *sidValidationGuard) sweepLocked(now time.Time) {
	for k, exp := range g.negative {
		if !now.Before(exp) {
			delete(g.negative, k)
		}
	}
}

// joinFlight returns the in-flight validation for key, if any.
func (g *sidValidationGuard) joinFlight(key [sha256.Size]byte) (*sidFlight, bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	f, ok := g.flight[key]
	return f, ok
}

// beginFlight registers a new flight for key, or returns the existing one (leader=false).
func (g *sidValidationGuard) beginFlight(key [sha256.Size]byte) (f *sidFlight, leader bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if existing, ok := g.flight[key]; ok {
		return existing, false
	}
	f = &sidFlight{done: make(chan struct{})}
	g.flight[key] = f
	return f, true
}

func (g *sidValidationGuard) endFlight(key [sha256.Size]byte, f *sidFlight) {
	g.mu.Lock()
	delete(g.flight, key)
	g.mu.Unlock()
	close(f.done)
}

// awaitFlight blocks until f finishes (sharing its result) or the request is cancelled.
func awaitFlight(r *http.Request, f *sidFlight) (string, error) {
	select {
	case <-f.done:
		return f.account, f.err
	case <-r.Context().Done():
		return "", fmt.Errorf("validate unknown sid: %w", r.Context().Err())
	}
}

// validateUnknownSID asks DSM who owns sid, through the guard. It returns the DSM account, or
// an error: errDSMSessionInvalid (DSM said no), errSIDRejected, errSIDRateLimited,
// errSIDValidationBusy (refused before reaching DSM), or a transport error from DSM.
//
// Concurrent requests carrying the SAME sid are coalesced (TASK-1082 D1/D2 QA): the first
// ("leader") makes the one DSM call, the rest wait for and share its answer. A client that
// has just logged in on DSM fans a screenful of requests out with a SID we have never seen;
// without coalescing, requests beyond the concurrency cap were denied though the SID was
// valid. Followers cost DSM nothing, so they are not charged to the per-IP budget or the
// concurrency cap; the cap still bounds DISTINCT SIDs. Nothing is cached from the flight
// except DSM's definitive "invalid"; an error result is shared with the burst that was
// waiting and then forgotten, so the next request retries (fail closed, never negative-cached).
func (s *Server) validateUnknownSID(r *http.Request, sid string) (string, error) {
	if len(sid) > sidMaxLen {
		return "", errSIDRejected
	}
	g := s.sidGuardFor()
	key := sha256.Sum256([]byte(sid))

	if g.negativeHit(key) {
		return "", errDSMSessionInvalid
	}
	if f, ok := g.joinFlight(key); ok {
		return awaitFlight(r, f)
	}
	if s.rateLimitExceeded(r, rateLimitBucketSIDValidation, sidValidationPerIPMax, sidValidationWindow) {
		log.Printf("[WebAPI] unknown-SID validation rate-limited remote=%s", remoteIP(r))
		return "", errSIDRateLimited
	}
	select {
	case g.sem <- struct{}{}:
		defer func() { <-g.sem }()
	default:
		// A flight may have started between joinFlight and here; sharing it beats failing.
		if f, ok := g.joinFlight(key); ok {
			return awaitFlight(r, f)
		}
		log.Printf("[WebAPI] unknown-SID validation at concurrency cap (%d): failing closed", sidValidationInflight)
		return "", errSIDValidationBusy
	}

	f, leader := g.beginFlight(key)
	if !leader {
		return awaitFlight(r, f)
	}
	// Whatever happens (including a panic in validate), the flight ends and its waiters are
	// released; an unset result is a closed-failure error, never an account.
	f.err = errors.New("sid validation did not complete")
	defer g.endFlight(key, f)

	account, err := g.validate(sid)
	switch {
	case err == nil && account != "":
		f.account, f.err = account, nil
	case err == nil || errors.Is(err, errDSMSessionInvalid):
		g.cacheNegative(key)
		f.account, f.err = "", errDSMSessionInvalid
	default:
		f.account, f.err = "", fmt.Errorf("validate unknown sid: %w", err)
	}
	return f.account, f.err
}
