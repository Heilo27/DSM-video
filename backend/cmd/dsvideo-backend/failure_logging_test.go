package main

// TASK-1052: every 5xx the backend answers leaves one log line naming the endpoint and the
// underlying cause, through ONE helper (writeFailure). These tests pin: (1) no source file
// writes a 5xx any other way, (2) real failures at representative sites log endpoint and
// cause, (3) no secret reaches the log, (4) a hot failing site cannot flood a NAS log, and
// (5) a 5xx that bypasses the helper still gets one fallback line.

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"

	"dsvideo/backend/internal/metadata"
	"dsvideo/backend/internal/transcode"
)

// ── (1) source scan ───────────────────────────────────────────────────────────────────────

var statusNames5xx = map[string]bool{
	"StatusInternalServerError": true, "StatusNotImplemented": true, "StatusBadGateway": true,
	"StatusServiceUnavailable": true, "StatusGatewayTimeout": true, "StatusHTTPVersionNotSupported": true,
	"StatusVariantAlsoNegotiates": true, "StatusInsufficientStorage": true, "StatusLoopDetected": true,
	"StatusNotExtended": true, "StatusNetworkAuthenticationRequired": true,
}

// find5xxWrites reports every call in src that writes a literal 5xx status (a named
// http.Status5xx or an integer 500-599) by writeErr, writeJSON, WriteHeader or http.Error,
// except inside the function named allowedIn. A status held in a variable cannot be read
// from syntax; those few passthroughs are covered by the fallback middleware instead.
func find5xxWrites(t *testing.T, filename string, src any, allowedIn string) []string {
	t.Helper()
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, filename, src, 0)
	if err != nil {
		t.Fatalf("parse %s: %v", filename, err)
	}
	is5xx := func(e ast.Expr) bool {
		switch v := e.(type) {
		case *ast.SelectorExpr:
			if id, ok := v.X.(*ast.Ident); ok && id.Name == "http" {
				return statusNames5xx[v.Sel.Name]
			}
		case *ast.BasicLit:
			if v.Kind == token.INT {
				n, err := strconv.Atoi(v.Value)
				return err == nil && n >= 500 && n <= 599
			}
		}
		return false
	}
	var found []string
	for _, decl := range f.Decls {
		fd, ok := decl.(*ast.FuncDecl)
		if !ok || fd.Body == nil || fd.Name.Name == allowedIn {
			continue
		}
		ast.Inspect(fd.Body, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			var name string
			statusArg := -1
			switch fn := call.Fun.(type) {
			case *ast.Ident:
				if fn.Name == "writeErr" || fn.Name == "writeJSON" {
					name, statusArg = fn.Name, 1
				}
			case *ast.SelectorExpr:
				if fn.Sel.Name == "WriteHeader" {
					name, statusArg = "WriteHeader", 0
				} else if id, ok := fn.X.(*ast.Ident); ok && id.Name == "http" && fn.Sel.Name == "Error" {
					name, statusArg = "http.Error", 2
				}
			}
			if statusArg >= 0 && statusArg < len(call.Args) && is5xx(call.Args[statusArg]) {
				found = append(found, fmt.Sprintf("%s:%d %s in %s", filename, fset.Position(call.Pos()).Line, name, fd.Name.Name))
			}
			return true
		})
	}
	return found
}

func TestFind5xxWritesSeesEveryWriterShape(t *testing.T) {
	src := `package p
func a(w W) { writeErr(w, http.StatusInternalServerError, "x") }
func b(w W) { writeJSON(w, http.StatusBadGateway, nil) }
func c(w W) { w.WriteHeader(503) }
func d(w W) { http.Error(w, "x", http.StatusServiceUnavailable) }
func e(w W, r R) { writeFailure(w, r, http.StatusInternalServerError, "x", nil) }
func f(w W) { writeErr(w, http.StatusNotFound, "x") }
func g(w W, s int) { w.WriteHeader(s) }
func writeFailureAt(w W) { writeErr(w, 500, "x") }
`
	got := find5xxWrites(t, "synthetic.go", src, "writeFailureAt")
	if len(got) != 4 {
		t.Fatalf("detector found %d writes %v, want exactly the 4 raw 5xx writers (a, b, c, d)", len(got), got)
	}
}

func TestEvery5xxIsWrittenThroughWriteFailure(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	calls := 0
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		src, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		for _, bad := range find5xxWrites(t, f, src, "writeFailureAt") {
			t.Errorf("raw 5xx write (route it through writeFailure so it is logged): %s", bad)
		}
		calls += strings.Count(string(src), "writeFailure(")
	}
	// Guards the scan going blind: the 100+ converted sites must all be visible as calls.
	if calls < 100 {
		t.Errorf("only %d writeFailure( call sites found in non-test source; the conversion is incomplete", calls)
	}
}

func TestFallbackMiddlewareIsInstalledAfterRecoverer(t *testing.T) {
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	s := string(src)
	rec := strings.Index(s, "r.Use(middleware.Recoverer)")
	fb := strings.Index(s, "r.Use(logUnloggedFailures)")
	if rec < 0 || fb < 0 || fb < rec {
		t.Fatalf("logUnloggedFailures must be installed after middleware.Recoverer (recoverer at %d, fallback at %d)", rec, fb)
	}
}

// ── helpers ───────────────────────────────────────────────────────────────────────────────

type fakeClock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *fakeClock) now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *fakeClock) advance(d time.Duration) {
	c.mu.Lock()
	c.t = c.t.Add(d)
	c.mu.Unlock()
}

// useFailureClock swaps the throttle's clock for a fake one and clears its state.
func useFailureClock(t *testing.T) *fakeClock {
	t.Helper()
	c := &fakeClock{t: time.Date(2026, 10, 18, 12, 0, 0, 0, time.UTC)}
	saved := failureNow
	failureNow = c.now
	resetFailureSites()
	t.Cleanup(func() { failureNow = saved; resetFailureSites() })
	return c
}

func failureLines(logs *bytes.Buffer) []string {
	var out []string
	for _, l := range strings.Split(logs.String(), "\n") {
		if strings.Contains(l, "[5xx]") {
			out = append(out, l)
		}
	}
	return out
}

func wantOneFailureLine(t *testing.T, logs *bytes.Buffer, wants ...string) string {
	t.Helper()
	lines := failureLines(logs)
	if len(lines) != 1 {
		t.Fatalf("want exactly one [5xx] log line, got %d:\n%s", len(lines), logs.String())
	}
	for _, w := range wants {
		if !strings.Contains(lines[0], w) {
			t.Errorf("log line %q is missing %q", lines[0], w)
		}
	}
	return lines[0]
}

func wantNoLeak(t *testing.T, logs *bytes.Buffer, secrets ...string) {
	t.Helper()
	for _, s := range secrets {
		if strings.Contains(logs.String(), s) {
			t.Errorf("log leaks %q:\n%s", s, logs.String())
		}
	}
}

// ── (2) forced real failures ──────────────────────────────────────────────────────────────

func TestFailureLogs_RepresentativeSites(t *testing.T) {
	cases := []struct {
		name       string
		status     int
		code       string
		method     string
		path       string // what the log must name (never the query)
		cause      string // text from the underlying error
		step       string // function that wrote it
		noLeak     []string
		force      func(t *testing.T) *httptest.ResponseRecorder
		skipReason string
	}{
		{
			name: "db_error: settings table gone", status: 500, code: "db_error",
			method: "GET", path: "/settings", cause: "no such table", step: "handleGetSettings",
			noLeak: []string{"TOKSECRET", "SIDSECRET", "Bearer "},
			force: func(t *testing.T) *httptest.ResponseRecorder {
				e := newQAEnv(t)
				if _, err := e.db.Exec(`DROP TABLE settings`); err != nil {
					t.Fatal(err)
				}
				return e.record(qaAlice, "GET", "/settings?token=TOKSECRET&_sid=SIDSECRET")
			},
		},
		{
			name: "tmdb_error: TMDb unreachable", status: 500, code: "tmdb_error",
			method: "GET", path: "/items/m1/tmdb-search", cause: "connect", step: "handleItemTMDbSearch",
			noLeak: []string{"TMDBKEYSECRET"},
			force: func(t *testing.T) *httptest.ResponseRecorder {
				e := newQAEnv(t)
				e.seedItem("m1", "Drama", nil)
				dead := httptest.NewServer(http.NotFoundHandler())
				base := dead.URL
				dead.Close()
				e.s.tmdbClient = metadata.NewTMDbClientWithBaseURL("TMDBKEYSECRET", base)
				return e.record(qaAlice, "GET", "/items/m1/tmdb-search?q=heat")
			},
		},
		{
			name: "ffmpeg_failed: ffmpeg binary cannot start", status: 500, code: "ffmpeg_failed",
			method: "GET", path: "/stream/abc", cause: "no such file", step: "handleRemuxStream",
			noLeak: []string{"STREAMTOKSECRET"},
			force: func(t *testing.T) *httptest.ResponseRecorder {
				s := &Server{cfg: Config{FFmpegPath: filepath.Join(t.TempDir(), "no-ffmpeg-here")},
					ffmpegLimiter: transcode.NewFFmpegLimiter(1)}
				w := httptest.NewRecorder()
				r := httptest.NewRequest("GET", "/stream/abc?token=STREAMTOKSECRET", nil)
				s.handleRemuxStream(w, r, PlaySession{Path: "/media/x.mkv"})
				return w
			},
		},
		{
			name: "503 transcode_busy: no ffmpeg slot", status: 503, code: "transcode_busy",
			method: "GET", path: "/stream/busy", cause: "context canceled", step: "handleRemuxStream",
			force: func(t *testing.T) *httptest.ResponseRecorder {
				lim := transcode.NewFFmpegLimiter(1)
				if err := lim.Acquire(context.Background()); err != nil {
					t.Fatal(err)
				}
				s := &Server{cfg: Config{FFmpegPath: "/bin/true"}, ffmpegLimiter: lim}
				ctx, cancel := context.WithCancel(context.Background())
				cancel()
				w := httptest.NewRecorder()
				r := httptest.NewRequest("GET", "/stream/busy", nil).WithContext(ctx)
				s.handleRemuxStream(w, r, PlaySession{Path: "/media/x.mkv"})
				return w
			},
		},
		{
			name: "502 quickconnect_resolve_failed: Synology lookup fails", status: 502, code: "quickconnect_resolve_failed",
			method: "POST", path: "/auth/quickconnect/resolve", cause: "lookup refused", step: "handleQuickConnectResolve",
			noLeak: []string{"hunter2"},
			force: func(t *testing.T) *httptest.ResponseRecorder {
				s := &Server{quickConnectResolver: func(context.Context, string) ([]qcCandidate, error) {
					return nil, errors.New("lookup refused for https://global.quickconnect.to/Serv.php?passwd=hunter2")
				}}
				w := httptest.NewRecorder()
				r := httptest.NewRequest("POST", "/auth/quickconnect/resolve", strings.NewReader(`{"quickConnectId":"my-nas"}`))
				r.RemoteAddr = "10.9.9.9:4000"
				s.handleQuickConnectResolve(w, r)
				return w
			},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			useFailureClock(t)
			logs := captureServerErrorLog(t)
			rec := tc.force(t)
			if rec.Code != tc.status || !strings.Contains(rec.Body.String(), `"`+tc.code+`"`) {
				t.Fatalf("answered %d %s, want %d %s", rec.Code, rec.Body.String(), tc.status, tc.code)
			}
			wantOneFailureLine(t, logs, tc.method+" "+tc.path, strconv.Itoa(tc.status), tc.code, tc.cause, tc.step)
			wantNoLeak(t, logs, tc.noLeak...)
			if strings.Contains(logs.String(), "?") && strings.Contains(strings.Join(failureLines(logs), "\n"), tc.path+"?") {
				t.Errorf("log line names the query string: %s", logs.String())
			}
		})
	}
}

// record is do() without the body/session plumbing: it returns the raw recorder so a test
// can assert a 5xx (do() only fails on 401).
func (e *qaEnv) record(u qaUser, method, path string) *httptest.ResponseRecorder {
	e.t.Helper()
	tok, err := e.s.issueToken(u.id, u.name)
	if err != nil {
		e.t.Fatalf("issueToken: %v", err)
	}
	req := httptest.NewRequest(method, path, strings.NewReader(""))
	req.Header.Set("Authorization", "Bearer "+tok)
	rec := httptest.NewRecorder()
	e.h.ServeHTTP(rec, req)
	return rec
}

// ── (3) redaction of the underlying error text ────────────────────────────────────────────

func TestRedactFailureText(t *testing.T) {
	cases := []struct{ in, want string }{
		{`Get "https://api.themoviedb.org/3/search/tv?api_key=abc123&query=heat": dial tcp: refused`,
			`Get "https://api.themoviedb.org/3/search/tv?api_key=[REDACTED]&query=heat": dial tcp: refused`},
		{`login failed: passwd=hunter2&account=bob`, `login failed: passwd=[REDACTED]&account=bob`},
		{`otp_code=123456 _sid=ABCDEF token=eyJ.a.b device_id=D1 did=D2`,
			`otp_code=[REDACTED] _sid=[REDACTED] token=[REDACTED] device_id=[REDACTED] did=[REDACTED]`},
		{`password=pw pin=1234`, `password=[REDACTED] pin=[REDACTED]`},
		{`upstream said Authorization: Bearer eyJhbGciOi.payload.sig rejected`, `upstream said Authorization: Bearer [REDACTED] rejected`},
		{`token_error while refreshing; tokenizer ok`, `token_error while refreshing; tokenizer ok`},
		{`no such table: settings`, `no such table: settings`},
	}
	for _, c := range cases {
		if got := redactFailureText(c.in); got != c.want {
			t.Errorf("redactFailureText(%q)\n got  %q\n want %q", c.in, got, c.want)
		}
	}
}

// ── (4) throttle ──────────────────────────────────────────────────────────────────────────

func TestRepeatedFailureAtOneSiteIsCollapsed(t *testing.T) {
	clock := useFailureClock(t)
	logs := captureServerErrorLog(t)
	fail := func(path string) *httptest.ResponseRecorder {
		w := httptest.NewRecorder()
		r := httptest.NewRequest("GET", path, nil)
		writeFailure(w, r, http.StatusServiceUnavailable, "playlist_not_ready", errors.New("timed out"))
		return w
	}
	for i := 0; i < 1000; i++ {
		if w := fail(fmt.Sprintf("/hls/s1/seg%d.ts", i)); w.Code != 503 {
			t.Fatalf("repeat %d answered %d; throttling the log must never change the response", i, w.Code)
		}
	}
	if got := len(failureLines(logs)); got != 3 {
		t.Fatalf("1000 repeats in one window wrote %d log lines, want 3:\n%s", got, logs.String())
	}

	// Still inside the window: a different site is not affected by this one being quiet.
	other := httptest.NewRecorder()
	writeFailure(other, httptest.NewRequest("GET", "/other", nil), 500, "db_error", errors.New("other site"))
	if got := len(failureLines(logs)); got != 4 {
		t.Fatalf("a different site must still log inside the first site's window; %d lines:\n%s", got, logs.String())
	}

	// The window rolls over: one summary with the suppressed count, then logging resumes.
	clock.advance(31 * time.Second)
	fail("/hls/s1/after.ts")
	lines := failureLines(logs)
	if len(lines) != 6 {
		t.Fatalf("after the window want 3+1 earlier lines + 1 summary + 1 fresh line = 6, got %d:\n%s", len(lines), logs.String())
	}
	if !strings.Contains(lines[4], "997") || !strings.Contains(strings.ToLower(lines[4]), "suppressed") {
		t.Errorf("summary line %q must state the 997 suppressed repeats", lines[4])
	}
	if !strings.Contains(lines[5], "/hls/s1/after.ts") {
		t.Errorf("the failure after the window must log normally, got %q", lines[5])
	}
}

// ── (5) fallback middleware ───────────────────────────────────────────────────────────────

func TestUnloggedFiveHundredGetsOneFallbackLine(t *testing.T) {
	useFailureClock(t)
	logs := captureServerErrorLog(t)
	r := chi.NewRouter()
	r.Use(logUnloggedFailures)
	r.Get("/bypass/{id}", func(w http.ResponseWriter, _ *http.Request) {
		if _, ok := w.(http.Flusher); !ok {
			t.Error("the fallback middleware must keep the ResponseWriter a Flusher (HLS and remux stream through it)")
		}
		w.WriteHeader(http.StatusBadGateway)
	})
	r.Get("/helper/{id}", func(w http.ResponseWriter, req *http.Request) {
		writeFailure(w, req, http.StatusInternalServerError, "db_error", errors.New("boom"))
	})
	r.Get("/fine", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	r.Get("/missing", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNotFound) })

	do := func(path string) int {
		rec := httptest.NewRecorder()
		r.ServeHTTP(rec, httptest.NewRequest("GET", path, nil))
		return rec.Code
	}

	if code := do("/bypass/42?token=FALLBACKSECRET"); code != 502 {
		t.Fatalf("bypass answered %d, want 502", code)
	}
	line := wantOneFailureLine(t, logs, "GET /bypass/42", "502")
	if strings.Contains(line, "FALLBACKSECRET") || strings.Contains(line, "token=") {
		t.Errorf("fallback line leaks the query: %q", line)
	}

	logs.Reset()
	if code := do("/helper/7"); code != 500 {
		t.Fatalf("helper route answered %d, want 500", code)
	}
	if got := len(failureLines(logs)); got != 1 {
		t.Fatalf("a failure written through writeFailure must log once, not again from the fallback; got %d:\n%s", got, logs.String())
	}

	logs.Reset()
	do("/fine")
	do("/missing")
	if got := len(failureLines(logs)); got != 0 {
		t.Fatalf("2xx/4xx answers must not log; got:\n%s", logs.String())
	}
}
