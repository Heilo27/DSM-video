package main

import (
	"log"
	"net/http"
	"time"
)

// DSM passthrough limits (TASK-1082 P1-1, FRD-001 FR-278).
//
// Several WebAPI branches forward a request, and whatever credential or session id it
// carries, to DSM's own auth.cgi / entry.cgi. Only `login` was counted, so every other
// branch gave an unauthenticated caller an unthrottled path to DSM: a session-id oracle
// (resume), an auth-subtype probe (SYNO.API.Auth.*), and a free way to make this server
// hammer DSM on the caller's behalf.
//
// Two budgets, both per client IP through the one rateLimitExceeded limiter:
//   - dsmauth: branches that carry a SID, token or credential to DSM.
//   - dsmmeta: metadata-only forwards (API.Info, DSM.Info, Encryption, Auth.Type,
//     Entry.Request) that real clients call a few times per session.
//
// login keeps its own, stricter "auth" budget (10/min) and is not counted again here.
const (
	rateLimitBucketDSMAuth = "dsmauth"
	rateLimitBucketDSMMeta = "dsmmeta"

	dsmAuthPassthroughMax = 60
	dsmMetaPassthroughMax = 120
	dsmPassthroughWindow  = time.Minute
)

// dsmPassthroughLimited counts one forwarded request against bucket and, when the budget
// is spent, writes the Synology-shaped 407 (the same code login uses) with Retry-After and
// reports true. The caller must return without forwarding.
func (s *Server) dsmPassthroughLimited(w http.ResponseWriter, r *http.Request, bucket string, max int) bool {
	if !s.rateLimitExceeded(r, bucket, max, dsmPassthroughWindow) {
		return false
	}
	// RemoteAddr only: it is the real client IP once trustedRealIP has run, and it is not
	// a credential. Never log the query string here.
	log.Printf("[WebAPI] DSM passthrough rate-limited bucket=%s remote=%s", bucket, r.RemoteAddr)
	w.Header().Set("Retry-After", "60")
	writeWebAPIError(w, 407)
	return true
}

func (s *Server) dsmAuthPassthroughLimited(w http.ResponseWriter, r *http.Request) bool {
	return s.dsmPassthroughLimited(w, r, rateLimitBucketDSMAuth, dsmAuthPassthroughMax)
}

func (s *Server) dsmMetaPassthroughLimited(w http.ResponseWriter, r *http.Request) bool {
	return s.dsmPassthroughLimited(w, r, rateLimitBucketDSMMeta, dsmMetaPassthroughMax)
}
