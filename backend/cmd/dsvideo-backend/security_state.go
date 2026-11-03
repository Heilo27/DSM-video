package main

import (
	"time"
)

// Bounds for the pre-auth did -> login bindings (TASK-1082 P2-5). The binding only has to
// survive the gap between a login response and the client's next Entry.Request call.
const (
	loginBindingTTL = 2 * time.Minute
	loginBindingMax = 4096
)

// loginBindingCount counts live entries. didToLoginBinding is a sync.Map, so the count is a
// walk; it only runs on login (rate-limited) and in the purge sweep.
func loginBindingCount() int {
	n := 0
	didToLoginBinding.Range(func(_, _ any) bool { n++; return true })
	return n
}

// sweepLoginBindings drops bindings older than loginBindingTTL.
func sweepLoginBindings(now time.Time) int {
	removed := 0
	didToLoginBinding.Range(func(k, v any) bool {
		b, ok := v.(loginBinding)
		if !ok || now.Sub(b.CreatedAt) > loginBindingTTL {
			didToLoginBinding.Delete(k)
			removed++
		}
		return true
	})
	return removed
}

// storeLoginBinding records did -> account, keeping the table bounded. At the cap it first
// sweeps expired entries; if the table is still full it refuses the new binding (the client
// then falls back to a fresh sign-in) rather than evicting a live user's binding. Returns
// whether the binding was stored.
func storeLoginBinding(did, account string, now time.Time) bool {
	if loginBindingCount() >= loginBindingMax {
		sweepLoginBindings(now)
		if loginBindingCount() >= loginBindingMax {
			return false
		}
	}
	didToLoginBinding.Store(did, loginBinding{Username: account, CreatedAt: now})
	return true
}

// sweepSecurityState is the purge goroutine's single call for the pre-auth caches.
func (s *Server) sweepSecurityState(now time.Time) {
	sweepLoginBindings(now)
	g := s.sidGuardFor()
	g.mu.Lock()
	g.sweepLocked(g.now())
	g.mu.Unlock()
}
