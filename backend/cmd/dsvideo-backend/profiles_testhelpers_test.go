package main

// Fixtures for FRD-002 profile tests (TASK-916). No assertions live here.

import (
	"context"
	"database/sql"
	"errors"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
	_ "modernc.org/sqlite"
)

// newProfilesTestServer opens a temp-file database with the production pragmas, runs the
// real migrate + migrateProfiles, and returns a Server over it. cfg.DBPath is set.
func newProfilesTestServer(t *testing.T) (*Server, *sql.DB) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "dsvideo.db")
	db, err := sql.Open("sqlite", path+"?_pragma=busy_timeout(30000)&_pragma=journal_mode(WAL)&_pragma=synchronous(1)")
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	if err := migrate(db); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	if err := migrateProfiles(db, path); err != nil {
		t.Fatalf("migrateProfiles: %v", err)
	}
	return &Server{db: db, cfg: Config{DBPath: path}}, db
}

// fakeDSMLogin makes DSM accept exactly okUser/okPass. Any other password is refused the way
// authenticateDSM refuses bad credentials ("invalid credentials").
func fakeDSMLogin(s *Server, okUser, okPass string) {
	s.dsmAuthOverride = func(_ context.Context, username, password, _, _ string) (*dsmUserInfo, error) {
		if strings.EqualFold(username, okUser) && password == okPass {
			return &dsmUserInfo{Username: okUser, DisplayName: okUser, SID: "test-sid"}, nil
		}
		return nil, errors.New("invalid credentials")
	}
}

// authedRequest builds a request whose context already carries the authenticated account,
// as authMiddleware would leave it (no JWT involved). profileHeader "" omits the header.
func authedRequest(method, path, body, userID, username, profileHeader string) *http.Request {
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	if profileHeader != "" {
		req.Header.Set("X-DSVideo-Profile", profileHeader)
	}
	return req.WithContext(context.WithValue(req.Context(), userKey, authedUser{ID: userID, Username: username}))
}

// withURLParam sets a chi URL parameter ({id}, {itemId}, …) on req for handlers called
// directly rather than through a router.
func withURLParam(req *http.Request, key, value string) *http.Request {
	rctx := chi.RouteContext(req.Context())
	if rctx == nil {
		rctx = chi.NewRouteContext()
		req = req.WithContext(context.WithValue(req.Context(), chi.RouteCtxKey, rctx))
	}
	rctx.URLParams.Add(key, value)
	return req
}

// serveWithResolver runs profileResolver(strict) and then h, as the router does.
func serveWithResolver(s *Server, h http.Handler, strict bool, req *http.Request) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	s.profileResolver(strict)(h).ServeHTTP(rec, req)
	return rec
}

// profilesTestRouter mounts the real /profiles* routes (lenient resolver included) with the
// URL patterns production uses, for requests built by authedRequest (auth is already in the
// context, so authMiddleware is not in the chain).
func profilesTestRouter(s *Server) http.Handler {
	r := chi.NewRouter()
	registerProfileRoutes(r, s)
	return r
}

// setPinClock replaces the PIN limiter's clock (lockout timing, FR-215).
func setPinClock(s *Server, now func() time.Time) {
	s.pinLimiter().setNow(now)
}
