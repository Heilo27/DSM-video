package main

import (
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
)

// Redaction protects the LOG. It must not corrupt the request.
//
// redactSensitiveParams used to pass the redacted request down the entire chain, on the
// stated reasoning that it "runs before routing resolves to a handler". chi routes whatever
// request the middleware calls next.ServeHTTP with, so that was false: every handler saw
// "[REDACTED]". getWebAPISession reads _sid from the query string, so query-param auth on
// the legacy Synology WebAPI layer could never succeed — masked by its form-body and cookie
// fallbacks, which is why it went unnoticed.
//
// These tests pin both halves at once, because either alone can be satisfied by a broken
// implementation: dropping the redaction entirely passes the handler test, and the original
// bug passes the log test.

// buildRedactionChain wires the middleware exactly as main() does, and captures both what
// the logger printed and what the handler saw.
//
// The "logger" here records r.RequestURI, because that is precisely what chi's real
// DefaultLogFormatter prints (middleware/logger.go:118). Asserting against r.URL instead
// would let the original bug pass: it rewrote URL and left RequestURI — the string that
// actually reaches the log — carrying the token in full.
func buildRedactionChain(t *testing.T, handler http.HandlerFunc) (*chi.Mux, *strings.Builder) {
	t.Helper()
	var logged strings.Builder
	r := chi.NewRouter()
	r.Use(redactSensitiveParams)
	r.Use(func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
			logged.WriteString(req.RequestURI)
			next.ServeHTTP(w, req)
		})
	})
	r.Use(restoreTrueURL)
	r.Get("/probe", handler)
	return r, &logged
}

func TestRedactionHidesTokenFromLogButNotFromHandler(t *testing.T) {
	const secret = "supersecret-session-value"

	var handlerSaw string
	r, logged := buildRedactionChain(t, func(w http.ResponseWriter, req *http.Request) {
		handlerSaw = req.URL.Query().Get("_sid")
		w.WriteHeader(http.StatusOK)
	})

	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, httptest.NewRequest("GET", "/probe?_sid="+secret, nil))

	// The handler must receive the REAL token, or query-param auth cannot work.
	if handlerSaw != secret {
		t.Errorf("handler read _sid = %q, want the real token %q", handlerSaw, secret)
	}
	// The log must NOT contain it.
	if strings.Contains(logged.String(), secret) {
		t.Errorf("the session token leaked into the log: %q", logged.String())
	}
	if !strings.Contains(logged.String(), "REDACTED") {
		t.Errorf("log does not show the redaction marker: %q", logged.String())
	}
}

func TestRedactionCoversTokenParamToo(t *testing.T) {
	const secret = "bearer-ish-token-value"

	var handlerSaw string
	r, logged := buildRedactionChain(t, func(w http.ResponseWriter, req *http.Request) {
		handlerSaw = req.URL.Query().Get("token")
		w.WriteHeader(http.StatusOK)
	})

	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, httptest.NewRequest("GET", "/probe?token="+secret, nil))

	if handlerSaw != secret {
		t.Errorf("handler read token = %q, want %q", handlerSaw, secret)
	}
	if strings.Contains(logged.String(), secret) {
		t.Errorf("token leaked into the log: %q", logged.String())
	}
}

// Non-sensitive params must survive untouched alongside a redacted one — the redaction
// re-encodes the query, so it is capable of dropping or reordering neighbours.
func TestRedactionPreservesOtherParams(t *testing.T) {
	var gotLimit, gotSid, gotFilter string
	r, _ := buildRedactionChain(t, func(w http.ResponseWriter, req *http.Request) {
		q := req.URL.Query()
		gotLimit, gotSid, gotFilter = q.Get("limit"), q.Get("_sid"), q.Get("filter")
		w.WriteHeader(http.StatusOK)
	})

	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, httptest.NewRequest("GET", "/probe?limit=16&_sid=abc&filter=justAdded", nil))

	if gotLimit != "16" || gotFilter != "justAdded" {
		t.Errorf("neighbouring params mangled: limit=%q filter=%q", gotLimit, gotFilter)
	}
	if gotSid != "abc" {
		t.Errorf("handler read _sid = %q, want %q", gotSid, "abc")
	}
}

// A request with no sensitive params must pass through completely unchanged.
func TestRedactionLeavesOrdinaryRequestsAlone(t *testing.T) {
	var gotRaw string
	r, _ := buildRedactionChain(t, func(w http.ResponseWriter, req *http.Request) {
		gotRaw = req.URL.RawQuery
		w.WriteHeader(http.StatusOK)
	})

	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, httptest.NewRequest("GET", "/probe?libraryId=lib_tv&limit=16", nil))

	if gotRaw != "libraryId=lib_tv&limit=16" {
		t.Errorf("ordinary query was rewritten: %q", gotRaw)
	}
}

// The hand-rolled logger above imitates chi's. This runs the REAL chi DefaultLogFormatter,
// so the guarantee does not rest on my imitation being faithful — if a chi upgrade changes
// which field it prints, this fails.
func TestRealChiLoggerDoesNotPrintTheToken(t *testing.T) {
	const secret = "token-the-real-logger-must-not-print"

	var out strings.Builder
	r := chi.NewRouter()
	r.Use(redactSensitiveParams)
	r.Use(middleware.RequestLogger(&middleware.DefaultLogFormatter{
		Logger:  log.New(&out, "", 0),
		NoColor: true,
	}))
	r.Use(restoreTrueURL)

	var handlerSaw string
	r.Get("/probe", func(w http.ResponseWriter, req *http.Request) {
		handlerSaw = req.URL.Query().Get("_sid")
	})

	r.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest("GET", "/probe?_sid="+secret, nil))

	if strings.Contains(out.String(), secret) {
		t.Errorf("chi's real logger printed the token: %q", out.String())
	}
	if !strings.Contains(out.String(), "REDACTED") {
		t.Errorf("chi's real logger shows no redaction marker: %q", out.String())
	}
	if handlerSaw != secret {
		t.Errorf("handler read _sid = %q, want the real token", handlerSaw)
	}
}

// The handler must get a correct RequestURI too, not just a correct URL.
//
// Anything that reads the raw request line — proxying, building a redirect, deriving a
// canonical URL — would otherwise see "[REDACTED]" in place of the real token. Restoring
// only r.URL leaves that stale, and no other test here notices.
func TestHandlerSeesTheTrueRequestURI(t *testing.T) {
	const secret = "sid-that-must-survive-to-the-handler"

	var gotRequestURI string
	r, _ := buildRedactionChain(t, func(w http.ResponseWriter, req *http.Request) {
		gotRequestURI = req.RequestURI
		w.WriteHeader(http.StatusOK)
	})

	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, httptest.NewRequest("GET", "/probe?_sid="+secret, nil))

	if strings.Contains(gotRequestURI, "REDACTED") {
		t.Errorf("handler's RequestURI is still redacted: %q", gotRequestURI)
	}
	if !strings.Contains(gotRequestURI, secret) {
		t.Errorf("handler's RequestURI = %q, want it to carry the real token", gotRequestURI)
	}
}

// redactedQuery is the pure core; check it does not mutate its input, since the caller
// hands it the map returned by r.URL.Query().
func TestRedactedQueryDoesNotMutateInput(t *testing.T) {
	in := map[string][]string{"_sid": {"real"}, "limit": {"16"}}
	out, ok := redactedQuery(in)
	if !ok {
		t.Fatal("redactedQuery reported nothing to redact for a query containing _sid")
	}
	if in["_sid"][0] != "real" {
		t.Errorf("input was mutated: _sid is now %q", in["_sid"][0])
	}
	if out.Get("_sid") != "[REDACTED]" {
		t.Errorf("output not redacted: %q", out.Get("_sid"))
	}
	if out.Get("limit") != "16" {
		t.Errorf("output dropped a neighbour: limit=%q", out.Get("limit"))
	}
}
