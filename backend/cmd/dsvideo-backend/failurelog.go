package main

// TASK-1052: every 5xx this server answers leaves a log line naming the endpoint, the status,
// the code, the step and the underlying error. Before this, db_error, tmdb_error, ffmpeg_failed
// and ~100 other failures answered "try again" and wrote nothing, so an on-device failure could
// not be traced on the NAS (TASK-1048 fixed only server_error).
//
// ONE helper owns it (writeFailure), so a new 5xx site cannot forget the log: a source-scan test
// fails the build when any writeErr/writeJSON/WriteHeader/http.Error writes a literal 5xx outside
// writeFailureAt. A 5xx that still bypasses the helper (a variable status passed through from
// DSM, a direct WriteHeader) gets one fallback line from logUnloggedFailures.
//
// Secrets: the line carries the method and the path, never the query string, and the
// underlying error text is scrubbed first (redactFailureText) because Go's HTTP client puts the
// full request URL, api_key and passwd included, into its errors.

import (
	"context"
	"errors"
	"log"
	"net/http"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
)

const (
	// failureBurst is how many log lines one failure site may write per failureWindow. A hot
	// failing site (an HLS segment poll answering 503 several times a second) would otherwise
	// fill a NAS log; the rest are counted and summarised.
	failureBurst  = 3
	failureWindow = 30 * time.Second
	// maxFailureTextLen bounds the underlying error text in one line.
	maxFailureTextLen = 400
)

// failureNow is the throttle's clock; tests replace it.
var failureNow = time.Now

type failureSiteState struct {
	windowStart time.Time
	logged      int
	suppressed  int
}

var (
	failureMu    sync.Mutex
	failureSites = map[string]*failureSiteState{}
)

// resetFailureSites forgets every site's window. Tests use it so one test's repeats do not
// silence the next test's first failure.
func resetFailureSites() {
	failureMu.Lock()
	failureSites = map[string]*failureSiteState{}
	failureMu.Unlock()
}

// failureCallSite names the line of code that produced a failure.
type failureCallSite struct {
	key string // file:line, the throttle key
	fn  string // function, shown as the step when the caller gives none
}

// callSiteOf returns the call site skip frames above its caller (1 = the caller of the
// function that calls callSiteOf).
func callSiteOf(skip int) failureCallSite {
	pc, file, line, ok := runtime.Caller(skip + 1)
	if !ok {
		return failureCallSite{key: "unknown", fn: "unknown"}
	}
	fn := "unknown"
	if f := runtime.FuncForPC(pc); f != nil {
		fn = strings.TrimPrefix(f.Name(), "main.")
	}
	if i := strings.LastIndex(file, "/"); i >= 0 {
		file = file[i+1:]
	}
	return failureCallSite{key: file + ":" + strconv.Itoa(line), fn: fn}
}

// writeFailure answers a 5xx and logs why. It is THE way to write a 5xx status: method, path
// (never the query), status, code, the calling function and the underlying error (err may be
// nil when the failure is a state, not an error). The response is identical to writeErr's.
func writeFailure(w http.ResponseWriter, r *http.Request, status int, code string, err error) {
	writeFailureAt(w, r, status, code, "", callSiteOf(1), err)
}

// writeFailureAt is writeFailure with an explicit step and call site, for helpers that wrap
// it (writeServerError names its own step). It is the one place a 5xx status is written.
func writeFailureAt(w http.ResponseWriter, r *http.Request, status int, code, step string, site failureCallSite, err error) {
	if step == "" {
		step = site.fn
	}
	logFailure(r, status, code, step, site.key+" "+code, err)
	markFailureLogged(r)
	writeErr(w, status, code)
}

// logFailure writes the line, subject to the per-site throttle.
func logFailure(r *http.Request, status int, code, step, siteKey string, err error) {
	method, path := "-", "-"
	if r != nil {
		method = r.Method
		if r.URL != nil {
			path = r.URL.Path
		}
	}
	cause := "none"
	if err != nil {
		cause = redactFailureText(err.Error())
	}
	emitThrottled(siteKey, func() {
		log.Printf("[5xx] %s %s %d %s step=%s: %s", method, path, status, code, step, cause)
	}, func(n int) {
		log.Printf("[5xx] %d more %d %s failures suppressed at %s in the last %ds", n, status, code, step, int(failureWindow/time.Second))
	})
}

// emitThrottled runs line() for the first failureBurst events of a site per window. Later
// events are only counted; the first event after the window ends first emits one summary()
// with the suppressed count, then starts a new window. The summary rides on the next event
// rather than a timer, so a site that stops failing never wakes a goroutine for it.
func emitThrottled(siteKey string, line func(), summary func(suppressed int)) {
	now := failureNow()
	failureMu.Lock()
	st := failureSites[siteKey]
	if st == nil {
		st = &failureSiteState{windowStart: now}
		failureSites[siteKey] = st
	}
	var report int
	if now.Sub(st.windowStart) >= failureWindow {
		report = st.suppressed
		*st = failureSiteState{windowStart: now}
	}
	doLine := false
	if st.logged < failureBurst {
		st.logged++
		doLine = true
	} else {
		st.suppressed++
	}
	failureMu.Unlock()

	if report > 0 {
		summary(report)
	}
	if doLine {
		line()
	}
}

// Causes for failures that are a state, not an error value. Named once so the three
// itemExists sites (and the two image-cache sites) say the same thing in the log.
var (
	errItemLookupUnavailable = errors.New("item existence check failed (the query error is logged by itemExists)")
	errImageCacheUnavailable = errors.New("image cache is not configured")
)

// ── "already logged" flag, for the fallback middleware ──────────────────────────────────────

type failureStateKey struct{}

type failureState struct{ logged atomic.Bool }

func markFailureLogged(r *http.Request) {
	if r == nil {
		return
	}
	if st, ok := r.Context().Value(failureStateKey{}).(*failureState); ok {
		st.logged.Store(true)
	}
}

// logUnloggedFailures is the safety net: a 5xx written without writeFailure (a DSM status
// passed straight through, a direct WriteHeader, a library) still leaves one line. A response
// that went through writeFailure is not logged again.
func logUnloggedFailures(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		st := &failureState{}
		r = r.WithContext(context.WithValue(r.Context(), failureStateKey{}, st))
		ww := middleware.NewWrapResponseWriter(w, r.ProtoMajor)
		next.ServeHTTP(ww, r)
		status := ww.Status()
		if status < 500 || st.logged.Load() {
			return
		}
		route := "unmatched"
		if rc := chi.RouteContext(r.Context()); rc != nil {
			if p := rc.RoutePattern(); p != "" {
				route = r.Method + " " + p
			}
		}
		logFailure(r, status, "unlogged", "fallback", "fallback "+route+" "+strconv.Itoa(status),
			errUnloggedFailure)
	})
}

var errUnloggedFailure = unloggedFailureError{}

type unloggedFailureError struct{}

func (unloggedFailureError) Error() string {
	return "5xx written without writeFailure (status passed through or written directly); the handler did not log a cause"
}

// ── redaction of the underlying error text ──────────────────────────────────────────────────

// failureSecretNames are the names whose VALUES never reach a log: everything the query
// redaction already covers (sensitiveQueryParams, one definition) plus the credentials that
// show up in error text rather than in a request line.
var failureSecretNames = append(append([]string{}, sensitiveQueryParams...),
	"sid", "access_token", "refresh_token", "id_token", "password", "pin", "otp",
	"api_key", "apikey", "secret", "client_secret")

var (
	failureKeyValueRE = regexp.MustCompile(`(?i)(^|[^A-Za-z0-9])(` + strings.Join(quoteAll(failureSecretNames), "|") + `)=[^&\s"'<>)]+`)
	failureJSONRE     = regexp.MustCompile(`(?i)("(?:` + strings.Join(quoteAll(failureSecretNames), "|") + `)"\s*:\s*")[^"]*"`)
	failureBearerRE   = regexp.MustCompile(`(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+`)
	failureCookieRE   = regexp.MustCompile(`(?i)((?:set-)?cookie:\s*)[^\r\n]*`)
)

func quoteAll(in []string) []string {
	out := make([]string, len(in))
	for i, s := range in {
		out[i] = regexp.QuoteMeta(s)
	}
	return out
}

// redactFailureText scrubs credentials out of an error's text and keeps it one bounded line.
func redactFailureText(s string) string {
	s = failureKeyValueRE.ReplaceAllString(s, "${1}${2}=[REDACTED]")
	s = failureJSONRE.ReplaceAllString(s, `${1}[REDACTED]"`)
	s = failureBearerRE.ReplaceAllString(s, "${1}[REDACTED]")
	s = failureCookieRE.ReplaceAllString(s, "${1}[REDACTED]")
	s = strings.Join(strings.Fields(s), " ") // one line: no newline can forge a second log entry
	if len(s) > maxFailureTextLen {
		s = s[:maxFailureTextLen] + "..."
	}
	return s
}
