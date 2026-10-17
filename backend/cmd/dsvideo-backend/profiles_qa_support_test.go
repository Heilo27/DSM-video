package main

// QA harness for FRD-002 / TASK-916 part A. Every request goes through the REAL router
// (registerAPIRoutes: authMiddleware + profileResolver + handlers) with a real signed JWT,
// so wiring mistakes in main.go are visible. No assertions on implementation internals.

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/go-chi/chi/v5"
)

type qaUser struct{ id, name string }

var (
	qaAlice = qaUser{"u_alice", "alice"}
	qaBob   = qaUser{"u_bob", "bob"}
)

type qaResp struct {
	code int
	hdr  http.Header
	raw  []byte
	js   map[string]any
}

func (r qaResp) str(key string) string {
	v, _ := r.js[key].(string)
	return v
}

func (r qaResp) num(key string) int {
	v, _ := r.js[key].(float64)
	return int(v)
}

type qaEnv struct {
	t      *testing.T
	s      *Server
	db     *sql.DB
	dbPath string
	h      http.Handler
	bodies []string // every response body of the test, for leak sweeps
}

func newQAEnv(t *testing.T) *qaEnv {
	t.Helper()
	s, db := newProfilesTestServer(t)
	s.cfg.JWTSecret = "qa-profiles-secret-qa-profiles-secret"
	s.justAdded = newJustAddedCache() // main() builds this; the bare test Server does not
	r := chi.NewRouter()
	registerAPIRoutes(r, s)
	return &qaEnv{t: t, s: s, db: db, dbPath: s.cfg.DBPath, h: r}
}

// do sends one authenticated request. profile "" omits X-DSVideo-Profile. A 401 anywhere is
// reported as a defect: the token is valid, so 401 can only be a profile/PIN error leaking
// the "your session is invalid" meaning (FR-217).
func (e *qaEnv) do(u qaUser, method, path, body, profile string) qaResp {
	e.t.Helper()
	tok, err := e.s.issueToken(u.id, u.name)
	if err != nil {
		e.t.Fatalf("issueToken: %v", err)
	}
	var rd *strings.Reader
	if body != "" {
		rd = strings.NewReader(body)
	} else {
		rd = strings.NewReader("")
	}
	req := httptest.NewRequest(method, path, rd)
	req.Header.Set("Authorization", "Bearer "+tok)
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	if profile != "" {
		req.Header.Set("X-DSVideo-Profile", profile)
	}
	rec := httptest.NewRecorder()
	e.h.ServeHTTP(rec, req)
	resp := qaResp{code: rec.Code, hdr: rec.Header(), raw: rec.Body.Bytes()}
	_ = json.Unmarshal(resp.raw, &resp.js)
	e.bodies = append(e.bodies, string(resp.raw))
	if resp.code == http.StatusUnauthorized {
		e.t.Errorf("%s %s answered 401 (%s): a valid session must never get 401 (FR-217)", method, path, resp.raw)
	}
	return resp
}

func jb(m map[string]any) string {
	b, err := json.Marshal(m)
	if err != nil {
		panic(err)
	}
	return string(b)
}

// wantErr asserts status + error code, with evidence of the raw body on failure.
func wantErr(t *testing.T, r qaResp, status int, code string) {
	t.Helper()
	if r.code != status || r.str("error") != code {
		t.Errorf("got %d %s, want %d {error:%q}", r.code, r.raw, status, code)
	}
}

func wantOK(t *testing.T, r qaResp, status int) {
	t.Helper()
	if r.code != status {
		t.Fatalf("got %d %s, want %d", r.code, r.raw, status)
	}
}

// profiles lists the account's profiles via the API (creating the owner lazily).
func (e *qaEnv) profiles(u qaUser) []map[string]any {
	e.t.Helper()
	r := e.do(u, "GET", "/profiles", "", "")
	wantOK(e.t, r, 200)
	raw, _ := r.js["profiles"].([]any)
	out := make([]map[string]any, 0, len(raw))
	for _, p := range raw {
		out = append(out, p.(map[string]any))
	}
	return out
}

func (e *qaEnv) ownerID(u qaUser) string {
	e.t.Helper()
	for _, p := range e.profiles(u) {
		if p["isOwner"] == true {
			return p["id"].(string)
		}
	}
	e.t.Fatalf("account %s has no owner profile", u.id)
	return ""
}

func (e *qaEnv) profileByName(u qaUser, name string) map[string]any {
	for _, p := range e.profiles(u) {
		if p["name"] == name {
			return p
		}
	}
	return nil
}

// setOwnerPin gives the owner its first PIN (FR-212: no ownerPin needed for the first one).
func (e *qaEnv) setOwnerPin(u qaUser, pin string) string {
	e.t.Helper()
	id := e.ownerID(u)
	r := e.do(u, "PATCH", "/profiles/"+id, jb(map[string]any{"pin": pin}), "")
	wantOK(e.t, r, 200)
	return id
}

// create makes a profile with the owner PIN and returns the response.
func (e *qaEnv) create(u qaUser, ownerPin, name string, level int, extra map[string]any) qaResp {
	body := map[string]any{"ownerPin": ownerPin, "name": name, "maxAgeLevel": level}
	for k, v := range extra {
		body[k] = v
	}
	return e.do(u, "POST", "/profiles", jb(body), "")
}

func (e *qaEnv) mustCreate(u qaUser, ownerPin, name string, level int, extra map[string]any) string {
	e.t.Helper()
	r := e.create(u, ownerPin, name, level, extra)
	wantOK(e.t, r, 201)
	return r.str("id")
}

func (e *qaEnv) count(query string, args ...any) int {
	e.t.Helper()
	var n int
	if err := e.db.QueryRow(query, args...).Scan(&n); err != nil {
		e.t.Fatalf("count %q: %v", query, err)
	}
	return n
}

func (e *qaEnv) profileRowCount(userID string) int {
	return e.count(`SELECT COUNT(*) FROM profiles WHERE user_id = ?`, userID)
}

// seedItem inserts a library item. cert nil means NULL content_rating (unrated).
func (e *qaEnv) seedItem(id, genres string, cert *string) {
	e.t.Helper()
	_, err := e.db.Exec(`INSERT INTO items(id, library_id, type, title, path, added_at, updated_at, genres, content_rating)
		VALUES(?, 'lib1', 'movie', ?, ?, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', ?, ?)`,
		id, id, "/media/"+id+".mkv", genres, cert)
	if err != nil {
		e.t.Fatalf("seed item %s: %v", id, err)
	}
}

func sp(s string) *string { return &s }
