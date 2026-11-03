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

type sidValidationGuard struct {
	mu       sync.Mutex
	negative map[[sha256.Size]byte]time.Time // sha256(sid) -> expiry; the SID itself is never kept
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

// validateUnknownSID asks DSM who owns sid, through the guard. It returns the DSM account, or
// an error: errDSMSessionInvalid (DSM said no), errSIDRejected, errSIDRateLimited,
// errSIDValidationBusy (refused before reaching DSM), or a transport error from DSM.
func (s *Server) validateUnknownSID(r *http.Request, sid string) (string, error) {
	if len(sid) > sidMaxLen {
		return "", errSIDRejected
	}
	g := s.sidGuardFor()
	key := sha256.Sum256([]byte(sid))

	if g.negativeHit(key) {
		return "", errDSMSessionInvalid
	}
	if s.rateLimitExceeded(r, rateLimitBucketSIDValidation, sidValidationPerIPMax, sidValidationWindow) {
		log.Printf("[WebAPI] unknown-SID validation rate-limited remote=%s", remoteIP(r))
		return "", errSIDRateLimited
	}
	select {
	case g.sem <- struct{}{}:
		defer func() { <-g.sem }()
	default:
		log.Printf("[WebAPI] unknown-SID validation at concurrency cap (%d): failing closed", sidValidationInflight)
		return "", errSIDValidationBusy
	}

	account, err := g.validate(sid)
	switch {
	case err == nil && account != "":
		return account, nil
	case err == nil || errors.Is(err, errDSMSessionInvalid):
		g.cacheNegative(key)
		return "", errDSMSessionInvalid
	default:
		return "", fmt.Errorf("validate unknown sid: %w", err)
	}
}
