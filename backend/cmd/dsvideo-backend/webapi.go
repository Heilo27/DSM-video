package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"hash/fnv"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"dsvideo/backend/internal/metadata"
)

// -------------------------
// Video Station WebAPI Compatibility Layer
// -------------------------
// Implements the Synology Video Station WebAPI protocol so that the
// official DS Video iOS app can connect to this server as if it were
// a genuine Video Station instance.

func isDSVideoUA(ua string) bool {
	return strings.Contains(ua, "DS_video") || strings.Contains(ua, "DS.video") || strings.Contains(ua, "DSvideo") || strings.Contains(ua, "Synology-DS_video")
}

// SessionStore manages SID-based sessions (maps SID -> authedUser + JWT token).
type SessionStore struct {
	mu       sync.RWMutex
	sessions map[string]*WebAPISession
}

type WebAPISession struct {
	SID       string
	UserID    string
	Username  string
	Token     string // JWT token for internal use
	DeviceID  string
	CreatedAt time.Time
}

func NewSessionStore() *SessionStore {
	return &SessionStore{
		sessions: make(map[string]*WebAPISession),
	}
}

func (ss *SessionStore) Create(userID, username, token, deviceID string) *WebAPISession {
	sid := randID("")
	if deviceID == "" {
		deviceID = randID("did_")
	}
	session := &WebAPISession{
		SID:       sid,
		UserID:    userID,
		Username:  username,
		Token:     token,
		DeviceID:  deviceID,
		CreatedAt: time.Now(),
	}
	ss.mu.Lock()
	ss.sessions[sid] = session
	ss.mu.Unlock()
	return session
}

func (ss *SessionStore) Get(sid string) *WebAPISession {
	ss.mu.RLock()
	defer ss.mu.RUnlock()
	return ss.sessions[sid]
}

func (ss *SessionStore) Delete(sid string) {
	ss.mu.Lock()
	delete(ss.sessions, sid)
	ss.mu.Unlock()
}

// CleanupExpired removes sessions whose CreatedAt is older than maxAge.
// It also removes them from the persistent SQLite store when a db handle is provided.
func (ss *SessionStore) CleanupExpired(maxAge time.Duration, db *sql.DB) int {
	cutoff := time.Now().Add(-maxAge)
	ss.mu.Lock()
	var expired []string
	for sid, session := range ss.sessions {
		if session.CreatedAt.Before(cutoff) {
			expired = append(expired, sid)
			delete(ss.sessions, sid)
		}
	}
	ss.mu.Unlock()
	for _, sid := range expired {
		deletePersistedSession(db, sid)
	}
	return len(expired)
}

// Global session store (added to Server in route setup)
var webAPISessions = NewSessionStore()

type loginBinding struct {
	Username  string
	CreatedAt time.Time
}

// DS File / DSM typically sets a long-lived `did` cookie on login, then sets the
// short-lived session cookie `id` via SYNO.Entry.Request.request. We keep a
// short-lived binding so we can create a local WebAPI session for the `id`
// cookie the client will actually use next.
var didToLoginBinding sync.Map // did string -> loginBinding

// persistSession writes a session to the SQLite database so it survives backend restarts.
func persistSession(db *sql.DB, session *WebAPISession) {
	if db == nil {
		return
	}
	_, err := db.Exec(
		`INSERT OR REPLACE INTO webapi_sessions (sid, user_id, username, token, device_id, created_at) VALUES (?, ?, ?, ?, ?, ?)`,
		session.SID, session.UserID, session.Username, session.Token, session.DeviceID, session.CreatedAt.Unix(),
	)
	if err != nil {
		log.Printf("[WebAPI] Failed to persist session %s: %v", session.SID[:min(16, len(session.SID))], err)
	}
}

// deletePersistedSession removes a session from SQLite.
func deletePersistedSession(db *sql.DB, sid string) {
	if db == nil {
		return
	}
	db.Exec(`DELETE FROM webapi_sessions WHERE sid = ?`, sid)
}

// loadPersistedSessions restores all sessions from SQLite into the in-memory store.
// Called once at startup to survive backend restarts.
func loadPersistedSessions(db *sql.DB) {
	if db == nil {
		return
	}
	rows, err := db.Query(`SELECT sid, user_id, username, token, device_id, created_at FROM webapi_sessions`)
	if err != nil {
		log.Printf("[WebAPI] Failed to load persisted sessions: %v", err)
		return
	}
	defer rows.Close()

	count := 0
	for rows.Next() {
		var s WebAPISession
		var createdUnix int64
		if err := rows.Scan(&s.SID, &s.UserID, &s.Username, &s.Token, &s.DeviceID, &createdUnix); err != nil {
			continue
		}
		s.CreatedAt = time.Unix(createdUnix, 0)
		webAPISessions.mu.Lock()
		webAPISessions.sessions[s.SID] = &s
		webAPISessions.mu.Unlock()
		count++
	}
	if count > 0 {
		log.Printf("[WebAPI] Restored %d session(s) from database", count)
	}
}

// writeWebAPISuccess writes a successful WebAPI response.
func writeWebAPISuccess(w http.ResponseWriter, data any) {
	// Match DSM's typical WebAPI content-type formatting.
	w.Header().Set("Content-Type", "application/json; charset=\"UTF-8\"")
	json.NewEncoder(w).Encode(map[string]any{
		"success": true,
		"data":    data,
	})
}

// writeWebAPIError writes an error WebAPI response.
func writeWebAPIError(w http.ResponseWriter, code int) {
	// Match DSM's typical WebAPI content-type formatting.
	w.Header().Set("Content-Type", "application/json; charset=\"UTF-8\"")
	json.NewEncoder(w).Encode(map[string]any{
		"success": false,
		"error":   map[string]any{"code": code},
	})
}

// proxyFormToDSM posts r.Form to a DSM CGI endpoint and returns status, headers, and body.
// This is used to transparently proxy auth/encryption flows that some DS Video versions
// expect DSM to handle (e.g. RSA-encrypted password handshake).
func (s *Server) proxyFormToDSM(r *http.Request, dsmURL string) (int, http.Header, []byte, error) {
	_ = r.ParseForm()

	noRedirect := func(req *http.Request, via []*http.Request) error {
		return http.ErrUseLastResponse
	}
	client := &http.Client{Timeout: 10 * time.Second, CheckRedirect: noRedirect}

	body := strings.NewReader(r.Form.Encode())
	req, err := http.NewRequestWithContext(r.Context(), http.MethodPost, dsmURL, body)
	if err != nil {
		return 0, nil, nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	if cookie := r.Header.Get("Cookie"); cookie != "" {
		req.Header.Set("Cookie", cookie)
	}

	resp, err := client.Do(req)
	if err != nil {
		return 0, nil, nil, err
	}
	defer resp.Body.Close()

	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return 0, nil, nil, err
	}
	return resp.StatusCode, resp.Header, b, nil
}

func (s *Server) writeProxiedResponse(w http.ResponseWriter, status int, hdr http.Header, body []byte) {
	for key, vals := range hdr {
		for _, v := range vals {
			w.Header().Add(key, v)
		}
	}
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

// getWebAPISession extracts and validates session from request.
// If the SID is not found in our local store, it validates against DSM
// (for the case where the official app authenticated through DSM ports directly).
func (s *Server) getWebAPISession(r *http.Request) *WebAPISession {
	// Check _sid query parameter
	sid := r.URL.Query().Get("_sid")

	// Check form body
	if sid == "" {
		sid = r.FormValue("_sid")
	}

	// Check Cookie header (official app uses Cookie: id=<sid>)
	if sid == "" {
		cookie := r.Header.Get("Cookie")
		for _, part := range strings.Split(cookie, ";") {
			kv := strings.SplitN(strings.TrimSpace(part), "=", 2)
			if len(kv) == 2 && kv[0] == "id" {
				sid = kv[1]
				break
			}
		}
	}

	ua := r.Header.Get("User-Agent")
	isDSVideo := isDSVideoUA(ua)

	if sid == "" {
		log.Printf("[WebAPI] getWebAPISession: no SID (isDSVideo=%v ua=%q cookie=%q)", isDSVideo, ua, r.Header.Get("Cookie"))
		return nil
	}

	sid = strings.TrimSpace(strings.Trim(sid, "\""))

	// Try our own session store first
	if session := webAPISessions.Get(sid); session != nil {
		return session
	}

	// SEC (TASK-726): For a DS Video UA presenting an unknown SID, validate it
	// against DSM FIRST and create the session under the REAL account. Previously
	// this branch trusted any DS Video UA's SID unconditionally — letting anyone on
	// the network forge a session. The insecure placeholder path now only runs when
	// AllowUnvalidatedDSVideo is explicitly enabled (trusted-LAN workaround for
	// fragile DS Video builds; never safe when port-forwarded).
	if isDSVideo {
		sidPrefix := func() string {
			if len(sid) > 16 {
				return sid[:16]
			}
			return sid
		}

		if account, vErr := s.validateDSMSession(sid); vErr == nil && account != "" {
			userID := "u_" + sanitizeID(account)
			if token, err := s.issueToken(userID, account); err == nil {
				session := &WebAPISession{
					SID:       sid,
					UserID:    userID,
					Username:  account,
					Token:     token,
					DeviceID:  randID("did_"),
					CreatedAt: time.Now(),
				}
				webAPISessions.mu.Lock()
				webAPISessions.sessions[sid] = session
				webAPISessions.mu.Unlock()
				go persistSession(s.db, session)
				log.Printf("[WebAPI] getWebAPISession: DS Video SID %s... validated against DSM as %q", sidPrefix(), account)
				return session
			}
		}

		if s.cfg.AllowUnvalidatedDSVideo {
			user := "sid_" + sid
			userID := "u_" + sanitizeID(user)
			token, err := s.issueToken(userID, user)
			if err == nil {
				session := &WebAPISession{
					SID:       sid,
					UserID:    userID,
					Username:  user,
					Token:     token,
					DeviceID:  randID("did_"),
					CreatedAt: time.Now(),
				}
				webAPISessions.mu.Lock()
				webAPISessions.sessions[sid] = session
				webAPISessions.mu.Unlock()
				go persistSession(s.db, session)
				log.Printf("[WebAPI] getWebAPISession: accepted UNVALIDATED SID %s... for DS Video UA (AllowUnvalidatedDSVideo=true)", sidPrefix())
				return session
			}
			log.Printf("[WebAPI] getWebAPISession: DS Video fallback token issue failed for SID %s...: %v", sidPrefix(), err)
		} else {
			log.Printf("[WebAPI] getWebAPISession: DS Video SID %s... failed DSM validation and AllowUnvalidatedDSVideo is off — rejecting", sidPrefix())
		}
	}

	// SID not found in local store — log the prefix for diagnostics.
	log.Printf("[WebAPI] getWebAPISession: SID %s... not in store (store size=%d), trying DSM",
		func() string {
			if len(sid) > 16 {
				return sid[:16]
			}
			return sid
		}(), func() int {
			webAPISessions.mu.RLock()
			n := len(webAPISessions.sessions)
			webAPISessions.mu.RUnlock()
			return n
		}())

	// SID not in our store - it might be a DSM SID from the official app
	// authenticating through DSM's port 5000/5001 directly.
	// Validate against DSM and create a local session if valid.
	username, err := s.validateDSMSession(sid)
	if err != nil || username == "" {
		log.Printf("[WebAPI] getWebAPISession: DSM validation failed for SID %s...: %v",
			func() string {
				if len(sid) > 16 {
					return sid[:16]
				}
				return sid
			}(), err)
		return nil
	}

	// DSM validated the SID - create a local session for this user
	userID := "u_" + sanitizeID(username)
	token, err := s.issueToken(userID, username)
	if err != nil {
		log.Printf("[WebAPI] Failed to issue token for DSM session user %s: %v", username, err)
		return nil
	}

	// Store with the DSM's SID so subsequent calls find it immediately
	session := &WebAPISession{
		SID:       sid,
		UserID:    userID,
		Username:  username,
		Token:     token,
		DeviceID:  randID("did_"),
		CreatedAt: time.Now(),
	}
	webAPISessions.mu.Lock()
	webAPISessions.sessions[sid] = session
	webAPISessions.mu.Unlock()

	log.Printf("[WebAPI] Created session for DSM-authenticated user %s (sid=%s...)", username, sid[:min(16, len(sid))])
	return session
}

func cookieValue(r *http.Request, name string) string {
	cookie := r.Header.Get("Cookie")
	for _, part := range strings.Split(cookie, ";") {
		kv := strings.SplitN(strings.TrimSpace(part), "=", 2)
		if len(kv) == 2 && kv[0] == name {
			return kv[1]
		}
	}
	return ""
}

func setCookieValueFromHeaders(h http.Header, name string) string {
	for _, sc := range h.Values("Set-Cookie") {
		// Simple parse: "<name>=<value>;"
		if strings.HasPrefix(sc, name+"=") {
			rest := strings.TrimPrefix(sc, name+"=")
			if i := strings.Index(rest, ";"); i >= 0 {
				return rest[:i]
			}
			return rest
		}
	}
	return ""
}

// validateDSMSession validates a DSM-issued SID against DSM's SCGI handler.
// SYNO.API.Auth is NOT intercepted by our nginx entry.cgi rule (only
// API.Info/DSM.Info/VideoStation are), so this call falls through to SCGI
// without creating a forwarding loop.
// Called when the official DS Video app authenticates via DSM's native port
// and then calls our VideoStation endpoints with a SCGI-issued SID.
func (s *Server) validateDSMSession(sid string) (string, error) {
	// Use auth.cgi (not entry.cgi) to avoid any nginx interception rules for entry.cgi.
	form := url.Values{}
	form.Set("api", "SYNO.API.Auth")
	form.Set("version", "6")
	form.Set("method", "checkauth")
	// DSM's checkauth can be session-scoped. DS Video uses session=VideoStation.
	form.Set("session", "VideoStation")
	form.Set("_sid", sid)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "http://127.0.0.1:5000/webapi/auth.cgi", strings.NewReader(form.Encode()))
	if err != nil {
		return "", fmt.Errorf("validateDSMSession build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("validateDSMSession HTTP: %w", err)
	}
	defer resp.Body.Close()

	var result struct {
		Success bool `json:"success"`
		Data    struct {
			Account string `json:"account"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", fmt.Errorf("validateDSMSession decode: %w", err)
	}
	if !result.Success || result.Data.Account == "" {
		return "", fmt.Errorf("DSM session invalid or account missing")
	}
	return result.Data.Account, nil
}

// proxyAuthToAuthCGI forwards a non-DS Video SYNO.API.Auth request transparently
// to DSM's /webapi/auth.cgi. auth.cgi is not intercepted by our nginx rule so
// there is no forwarding loop. This allows DSM web UI and other Synology apps
// to authenticate normally even while our entry.cgi intercept is active.
func (s *Server) proxyAuthToAuthCGI(w http.ResponseWriter, r *http.Request) {
	// ParseForm ensures r.Form contains all parameters from both URL query
	// string and POST body. For GET requests where params are in the URL only,
	// r.Form may be unpopulated if r.FormValue was never called upstream.
	_ = r.ParseForm()

	// Must be a transparent proxy: forward request cookies, copy all response
	// headers (especially Set-Cookie) back to the client, and do NOT follow
	// redirects (DSM may issue a 3xx that the browser must handle itself).
	noRedirect := func(req *http.Request, via []*http.Request) error {
		return http.ErrUseLastResponse
	}
	client := &http.Client{Timeout: 10 * time.Second, CheckRedirect: noRedirect}

	body := strings.NewReader(r.Form.Encode())
	req, err := http.NewRequestWithContext(r.Context(), http.MethodPost, "http://127.0.0.1:5000/webapi/auth.cgi", body)
	if err != nil {
		log.Printf("[WebAPI] Auth proxy build request failed: %v", err)
		writeWebAPIError(w, 100)
		return
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	// Forward cookies so DSM can correlate the OTP session.
	if cookie := r.Header.Get("Cookie"); cookie != "" {
		req.Header.Set("Cookie", cookie)
	}

	resp, err := client.Do(req)
	if err != nil {
		log.Printf("[WebAPI] Auth proxy to auth.cgi failed: %v", err)
		writeWebAPIError(w, 100)
		return
	}
	defer resp.Body.Close()

	// Copy all response headers (Set-Cookie, etc.) before writing status.
	for key, vals := range resp.Header {
		for _, v := range vals {
			w.Header().Add(key, v)
		}
	}
	w.WriteHeader(resp.StatusCode)
	io.Copy(w, resp.Body)
}

// -------------------------
// /webapi/query.cgi - API Discovery
// -------------------------

func (s *Server) handleWebAPIQuery(w http.ResponseWriter, r *http.Request) {
	// Build the API directory by merging DSM's native APIs with our VideoStation APIs.
	apis := make(map[string]any)

	// 1. Read DSM's native .lib files to include all existing APIs
	dsmAPIs := readDSMLibFiles("/usr/syno/synoman/webapi")
	for name, info := range dsmAPIs {
		// Skip any existing VideoStation entries — we replace them
		if strings.HasPrefix(name, "SYNO.VideoStation") {
			continue
		}
		apis[name] = info
	}

	// 2. Always include standard DSM APIs (override any from .lib files with correct values).
	apis["SYNO.API.Auth"] = map[string]any{
		"path": "entry.cgi", "minVersion": 1, "maxVersion": 7,
	}
	apis["SYNO.API.Info"] = map[string]any{
		"path": "query.cgi", "minVersion": 1, "maxVersion": 2,
	}
	apis["SYNO.DSM.Info"] = map[string]any{
		"path": "entry.cgi", "minVersion": 1, "maxVersion": 2,
	}

	// 3. Add VideoStation APIs.
	//
	// CRITICAL ROUTING FIX: We advertise VideoStation content APIs at
	// "DSVideoServer/entry.cgi" instead of the standard "entry.cgi".
	//
	// Problem: nginx routes DS Video to our backend by matching the User-Agent
	// header (DS_video substring).  DS Video 3.4.5 appears to use a different
	// UA for post-login content requests (e.g. the default CFNetwork UA) compared
	// to the auth flow.  That causes content requests to fall through to the real
	// VideoStation SCGI handler, which rejects our SID with error 105 and triggers
	// an immediate "go back to login" in DS Video.
	//
	// Fix: the nginx location ^~ /webapi/DSVideoServer/ proxies ALL requests
	// unconditionally (no UA check), so DS Video content requests reach our backend
	// regardless of which User-Agent the app sends post-login.
	//
	// Auth APIs (SYNO.API.Auth, SYNO.API.Encryption) remain at "entry.cgi" because
	// they are called before our session cookie is set, and the UA-based nginx rule
	// correctly routes those initial requests.
	vs := "DSVideoServer/entry.cgi" // unconditionally proxied location
	apis["SYNO.VideoStation.Info"] = map[string]any{
		"path": vs, "minVersion": 1, "maxVersion": 6,
	}
	apis["SYNO.VideoStation2.Info"] = map[string]any{
		"path": vs, "minVersion": 1, "maxVersion": 2,
	}
	apis["SYNO.VideoStation2.Library"] = map[string]any{
		"path": vs, "minVersion": 1, "maxVersion": 3,
	}
	apis["SYNO.VideoStation2.Movie"] = map[string]any{
		"path": vs, "minVersion": 1, "maxVersion": 4,
	}
	apis["SYNO.VideoStation2.TVShow"] = map[string]any{
		"path": vs, "minVersion": 1, "maxVersion": 2,
	}
	apis["SYNO.VideoStation2.TVShowEpisode"] = map[string]any{
		"path": vs, "minVersion": 1, "maxVersion": 3,
	}
	apis["SYNO.VideoStation2.Streaming"] = map[string]any{
		"path": vs, "minVersion": 1, "maxVersion": 2,
	}
	apis["SYNO.VideoStation2.Poster"] = map[string]any{
		"path": vs, "minVersion": 1, "maxVersion": 1,
	}
	apis["SYNO.VideoStation2.WatchStatus"] = map[string]any{
		"path": vs, "minVersion": 1, "maxVersion": 1,
	}
	apis["SYNO.VideoStation2.File"] = map[string]any{
		"path": vs, "minVersion": 1, "maxVersion": 2,
	}
	apis["SYNO.VideoStation2.HomeSection"] = map[string]any{
		"path": vs, "minVersion": 1, "maxVersion": 1,
	}
	apis["SYNO.VideoStation.Streaming"] = map[string]any{
		"path": vs, "minVersion": 1, "maxVersion": 1,
	}
	apis["SYNO.VideoStation.Poster"] = map[string]any{
		"path": vs, "minVersion": 1, "maxVersion": 3,
	}
	apis["SYNO.VideoStation.Backdrop"] = map[string]any{
		"path": vs, "minVersion": 1, "maxVersion": 1,
	}

	log.Printf("[WebAPI] query.cgi: returning %d APIs (%d from DSM, VideoStation from us)",
		len(apis), len(dsmAPIs))
	writeWebAPISuccess(w, apis)
}

// readDSMLibFiles reads all .lib files from DSM's webapi directory and parses API definitions.
// DSM 7.x .lib files are JSON: {"API.Name": {"minVersion": N, "maxVersion": N, ...}, ...}
func readDSMLibFiles(dir string) map[string]map[string]any {
	apis := make(map[string]map[string]any)

	entries, err := os.ReadDir(dir)
	if err != nil {
		log.Printf("[WebAPI] Cannot read DSM webapi dir %s: %v", dir, err)
		return apis
	}

	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".lib") {
			continue
		}
		parseLibFile(filepath.Join(dir, entry.Name()), apis)
	}

	return apis
}

// parseLibFile parses a single DSM .lib file (JSON format on DSM 7.x).
// Format: {"SYNO.API.Name": {"minVersion": N, "maxVersion": N, ...}, ...}
func parseLibFile(path string, apis map[string]map[string]any) {
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()

	// DSM 7.x lib files are JSON objects mapping API name → API properties.
	var raw map[string]map[string]any
	if err := json.NewDecoder(f).Decode(&raw); err != nil {
		return
	}

	for name, info := range raw {
		apiEntry := map[string]any{
			"path": "entry.cgi", // DSM routes all APIs through entry.cgi
		}
		if v, ok := info["minVersion"]; ok {
			apiEntry["minVersion"] = v
		}
		if v, ok := info["maxVersion"]; ok {
			apiEntry["maxVersion"] = v
		}
		apis[name] = apiEntry
	}
}

// -------------------------
// SYNO.API.Info (via entry.cgi)
// -------------------------
// The official DS Video app queries API discovery via entry.cgi, not just query.cgi.

func (s *Server) handleWebAPIAPIInfo(w http.ResponseWriter, r *http.Request, method string) {
	if method != "query" {
		writeWebAPIError(w, 101)
		return
	}

	// Same logic as handleWebAPIQuery — return all available APIs.
	apis := make(map[string]any)

	// 1. Read DSM's native .lib files (only works on NAS)
	dsmAPIs := readDSMLibFiles("/usr/syno/synoman/webapi")
	for name, info := range dsmAPIs {
		if strings.HasPrefix(name, "SYNO.VideoStation") {
			continue
		}
		apis[name] = info
	}

	// 2. Essential DSM APIs (always present)
	apis["SYNO.API.Auth"] = map[string]any{
		"path": "entry.cgi", "minVersion": 1, "maxVersion": 7,
	}
	apis["SYNO.API.Info"] = map[string]any{
		"path": "query.cgi", "minVersion": 1, "maxVersion": 2,
	}
	apis["SYNO.DSM.Info"] = map[string]any{
		"path": "entry.cgi", "minVersion": 1, "maxVersion": 2,
	}

	// 3. VideoStation APIs — routed through DSVideoServer/entry.cgi (unconditional
	// nginx proxy, no UA matching required). This ensures post-login content requests
	// reach our backend regardless of what User-Agent DS Video uses.
	vs := "DSVideoServer/entry.cgi"
	apis["SYNO.VideoStation.Info"] = map[string]any{
		"path": vs, "minVersion": 1, "maxVersion": 6,
	}
	apis["SYNO.VideoStation2.Info"] = map[string]any{
		"path": vs, "minVersion": 1, "maxVersion": 2,
	}
	apis["SYNO.VideoStation2.Library"] = map[string]any{
		"path": vs, "minVersion": 1, "maxVersion": 3,
	}
	apis["SYNO.VideoStation2.Movie"] = map[string]any{
		"path": vs, "minVersion": 1, "maxVersion": 4,
	}
	apis["SYNO.VideoStation2.TVShow"] = map[string]any{
		"path": vs, "minVersion": 1, "maxVersion": 2,
	}
	apis["SYNO.VideoStation2.TVShowEpisode"] = map[string]any{
		"path": vs, "minVersion": 1, "maxVersion": 3,
	}
	apis["SYNO.VideoStation2.Streaming"] = map[string]any{
		"path": vs, "minVersion": 1, "maxVersion": 2,
	}
	apis["SYNO.VideoStation2.Poster"] = map[string]any{
		"path": vs, "minVersion": 1, "maxVersion": 1,
	}
	apis["SYNO.VideoStation2.WatchStatus"] = map[string]any{
		"path": vs, "minVersion": 1, "maxVersion": 1,
	}
	apis["SYNO.VideoStation2.File"] = map[string]any{
		"path": vs, "minVersion": 1, "maxVersion": 2,
	}
	apis["SYNO.VideoStation2.HomeSection"] = map[string]any{
		"path": vs, "minVersion": 1, "maxVersion": 1,
	}
	apis["SYNO.VideoStation.Streaming"] = map[string]any{
		"path": vs, "minVersion": 1, "maxVersion": 1,
	}
	apis["SYNO.VideoStation.Poster"] = map[string]any{
		"path": vs, "minVersion": 1, "maxVersion": 3,
	}
	apis["SYNO.VideoStation.Backdrop"] = map[string]any{
		"path": vs, "minVersion": 1, "maxVersion": 1,
	}

	// Filter by query parameter if provided (e.g., query=SYNO.VideoStation2)
	queryFilter := r.URL.Query().Get("query")
	if queryFilter == "" {
		queryFilter = r.FormValue("query")
	}
	if queryFilter != "" && queryFilter != "all" {
		filtered := make(map[string]any)
		filters := strings.Split(queryFilter, ",")
		for name, info := range apis {
			for _, f := range filters {
				f = strings.TrimSpace(f)
				if strings.HasPrefix(name, f) || name == f {
					filtered[name] = info
					break
				}
			}
		}
		apis = filtered
	}

	log.Printf("[WebAPI] SYNO.API.Info query: returning %d APIs", len(apis))
	writeWebAPISuccess(w, apis)
}

// -------------------------
// SYNO.DSM.Info
// -------------------------
// Returns fake DSM system info so the official app recognizes this as a DSM host.

func (s *Server) handleWebAPIDSMInfo(w http.ResponseWriter, r *http.Request, method string) {
	if method != "getinfo" && method != "get" {
		writeWebAPIError(w, 101)
		return
	}

	// Prefer proxying the native DSM response to match exact per-version fields.
	// This avoids fragile client crashes due to schema mismatches.
	if status, hdr, body, err := s.proxyFormToDSM(r, "http://127.0.0.1:5000/webapi/entry.cgi"); err == nil {
		s.writeProxiedResponse(w, status, hdr, body)
		return
	}

	hostname, _ := os.Hostname()
	if hostname == "" {
		hostname = "DSVideoServer"
	}

	writeWebAPISuccess(w, map[string]any{
		"model":            "DS923+",
		"ram":              4096,
		"serial":           "0000000000000",
		"temperature":      40,
		"temperature_warn": false,
		"time":             time.Now().Format("2006-01-02 15:04:05"),
		"timezone":         "America/New_York",
		"uptime":           86400,
		"version":          "7.2.2-72806",
		"version_string":   "DSM 7.2.2-72806",
		"hostname":         hostname,
	})
}

// -------------------------
// /webapi/entry.cgi - Main API Router
// -------------------------

func (s *Server) handleWebAPIEntry(w http.ResponseWriter, r *http.Request) {
	// Parse API parameters from query string or form body
	api := r.URL.Query().Get("api")
	if api == "" {
		api = r.FormValue("api")
	}
	method := r.URL.Query().Get("method")
	if method == "" {
		method = r.FormValue("method")
	}
	version := r.URL.Query().Get("version")
	if version == "" {
		version = r.FormValue("version")
	}

	// Log session state for every entry.cgi request — critical for diagnosing
	// why DS Video stops making requests after Info.get.
	{
		sid := r.URL.Query().Get("_sid")
		if sid == "" {
			sid = r.FormValue("_sid")
		}
		cookie := r.Header.Get("Cookie")
		var cookieSID string
		for _, part := range strings.Split(cookie, ";") {
			kv := strings.SplitN(strings.TrimSpace(part), "=", 2)
			if len(kv) == 2 && kv[0] == "id" {
				cookieSID = kv[1]
				break
			}
		}
		sessionValid := false
		if sid != "" {
			sessionValid = webAPISessions.Get(sid) != nil
		} else if cookieSID != "" {
			sessionValid = webAPISessions.Get(cookieSID) != nil
		}
		log.Printf("[WebAPI] %s %s.%s (v%s) sid_param=%v cookie_sid=%v session_valid=%v UA=%q",
			r.Method, api, method, version,
			sid != "", cookieSID != "", sessionValid,
			r.Header.Get("User-Agent"))
	}

	switch api {
	case "SYNO.API.Info":
		s.handleWebAPIAPIInfo(w, r, method)
	case "SYNO.API.Auth":
		s.handleWebAPIAuth(w, r, method)
	case "SYNO.Entry.Request":
		// DS File (and some DSM flows) call this right after login. DSM sets the
		// `id` cookie here, not in Auth.login. Proxy to DSM so cookies match what
		// the official clients expect.
		status, hdr, body, err := s.proxyFormToDSM(r, "http://127.0.0.1:5000/webapi/entry.cgi")
		if err != nil {
			log.Printf("[WebAPI] Entry.Request proxy failed: %v", err)
			writeWebAPIError(w, 100)
			return
		}

		// If DSM issued a new `id` cookie and the request carried `did`, bind
		// the new session ID to the username from the just-completed login.
		newID := setCookieValueFromHeaders(hdr, "id")
		did := cookieValue(r, "did")
		if newID != "" && did != "" {
			if v, ok := didToLoginBinding.Load(did); ok {
				if b, ok2 := v.(loginBinding); ok2 {
					// Only accept fresh bindings (2 minutes).
					if time.Since(b.CreatedAt) < 2*time.Minute && webAPISessions.Get(newID) == nil {
						userID := "u_" + sanitizeID(b.Username)
						token, tokErr := s.issueToken(userID, b.Username)
						if tokErr == nil {
							sess := &WebAPISession{
								SID:       newID,
								UserID:    userID,
								Username:  b.Username,
								Token:     token,
								DeviceID:  did,
								CreatedAt: time.Now(),
							}
							webAPISessions.mu.Lock()
							webAPISessions.sessions[newID] = sess
							webAPISessions.mu.Unlock()
							go persistSession(s.db, sess)
							log.Printf("[WebAPI] Entry.Request: bound did=%s... to id=%s... (user=%q)",
								func() string {
									if len(did) > 16 {
										return did[:16]
									}
									return did
								}(),
								func() string {
									if len(newID) > 16 {
										return newID[:16]
									}
									return newID
								}(),
								b.Username,
							)
						}
					}
				}
			}
		}

		s.writeProxiedResponse(w, status, hdr, body)
	case "SYNO.API.Auth.Type":
		// DSM web UI queries this before login to detect available auth types.
		// Returning "local" keeps the username/password form visible (proxying
		// to auth.cgi can make DSM hide the login form depending on settings).
		//
		// However, DS Video 3.x expects the native DSM response shape here, so
		// for DS Video UAs we proxy to DSM.
		if isDSVideoUA(r.Header.Get("User-Agent")) {
			status, hdr, body, err := s.proxyFormToDSM(r, "http://127.0.0.1:5000/webapi/auth.cgi")
			if err != nil {
				log.Printf("[WebAPI] Auth.Type proxy failed: %v", err)
				writeWebAPIError(w, 100)
				return
			}
			s.writeProxiedResponse(w, status, hdr, body)
			return
		}
		writeWebAPISuccess(w, map[string]any{"type": "local"})
	case "SYNO.API.Encryption":
		// Some DS Video versions require DSM's RSA encryption handshake
		// (SYNO.API.Encryption.getinfo) and will crash if it's missing. Proxy
		// to DSM's encryption.cgi (not entry.cgi) so DSM owns the cipher token.
		status, hdr, body, err := s.proxyFormToDSM(r, "http://127.0.0.1:5000/webapi/encryption.cgi")
		if err != nil {
			log.Printf("[WebAPI] Encryption proxy failed: %v", err)
			writeWebAPIError(w, 100)
			return
		}
		s.writeProxiedResponse(w, status, hdr, body)
	case "SYNO.DSM.Info":
		s.handleWebAPIDSMInfo(w, r, method)
	case "SYNO.VideoStation.Info":
		s.handleWebAPIInfo(w, r, method)
	case "SYNO.VideoStation2.Info":
		s.handleWebAPIInfo(w, r, method)
	case "SYNO.VideoStation2.Library":
		s.handleWebAPILibrary(w, r, method)
	case "SYNO.VideoStation2.Movie":
		s.handleWebAPIMovie(w, r, method)
	case "SYNO.VideoStation2.TVShow":
		s.handleWebAPITVShow(w, r, method)
	case "SYNO.VideoStation2.TVShowEpisode":
		s.handleWebAPITVShowEpisode(w, r, method)
	case "SYNO.VideoStation2.Streaming":
		s.handleWebAPIStreaming(w, r, method)
	case "SYNO.VideoStation2.Poster", "SYNO.VideoStation.Poster":
		s.handleWebAPIPoster(w, r, method)
	case "SYNO.VideoStation.Backdrop":
		s.handleWebAPIBackdrop(w, r, method)
	case "SYNO.VideoStation2.WatchStatus":
		s.handleWebAPIWatchStatus(w, r, method)
	case "SYNO.VideoStation2.File":
		s.handleWebAPIFile(w, r, method)
	case "SYNO.VideoStation2.HomeSection":
		s.handleWebAPIHomeSection(w, r, method)
	default:
		// Auth subtypes (SYNO.API.Auth.Type, SYNO.API.Auth.Key, etc.) — proxy
		// to auth.cgi so DSM handles them natively without any loop.
		if strings.HasPrefix(api, "SYNO.API.Auth") {
			s.proxyAuthToAuthCGI(w, r)
			return
		}
		if method == "getjs" {
			// DSM desktop init APIs expect JavaScript, not JSON. Return an empty
			// script so the desktop can continue loading without a parse error.
			w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
			w.WriteHeader(http.StatusOK)
			return
		}
		log.Printf("[WebAPI] Unknown API: %s", api)
		writeWebAPIError(w, 102) // No such API
	}
}

// -------------------------
// SYNO.API.Auth
// -------------------------

func (s *Server) handleWebAPIAuth(w http.ResponseWriter, r *http.Request, method string) {
	switch method {
	case "checkauth":
		// DS Video calls checkauth to verify the SID it will use for subsequent
		// VideoStation API calls. DSM sometimes returns 103 depending on session
		// context; to keep the client stable we validate against our session store
		// (and DSM on-demand) and return a success response when valid.
		session := s.getWebAPISession(r)
		if session == nil {
			// Match DSM's "permission denied/invalid session" semantics.
			writeWebAPIError(w, 103)
			return
		}
		writeWebAPISuccess(w, map[string]any{
			"account": session.Username,
		})

	case "resume":
		// Proxy non-DSVideo sessions (e.g. webman, FileStation) to auth.cgi so
		// the DSM web UI can resume its own sessions unaffected by our intercept.
		// "VideoStation" sessions are ours: the DS Video app uses session=VideoStation.
		sessionName := r.URL.Query().Get("session")
		if sessionName == "" {
			sessionName = r.FormValue("session")
		}
		ua := r.Header.Get("User-Agent")
		isDSVideo := isDSVideoUA(ua)
		if !isDSVideo && sessionName != "" && sessionName != "DSVideo" && sessionName != "VideoStation" {
			s.proxyAuthToAuthCGI(w, r)
			return
		}

		// DSVideo session resume: check our local store first.
		sid := r.URL.Query().Get("_sid")
		if sid == "" {
			sid = r.FormValue("_sid")
		}
		session := webAPISessions.Get(sid)
		if session == nil {
			// SID not in our store. If no session name was given, this is likely
			// a DSM native session (webman desktop loads without sending session=webman
			// on resume). Proxy to auth.cgi so DSM can validate it natively.
			if sessionName == "" {
				s.proxyAuthToAuthCGI(w, r)
				return
			}
			writeWebAPIError(w, 106) // Session timeout — app will do fresh login
			return
		}
		writeWebAPISuccess(w, map[string]any{
			"sid":     session.SID,
			"account": session.Username,
		})

	case "login":
		log.Printf("[WebAPI] Auth login ENTER (build=%s) ua=%q", BuildVersion, r.Header.Get("User-Agent"))
		// If the session belongs to another DSM app (e.g. webman, FileStation),
		// proxy the entire request to auth.cgi so DSM web UI login is unaffected.
		// "VideoStation" sessions are ours: the DS Video app uses session=VideoStation.
		sessionName := r.URL.Query().Get("session")
		if sessionName == "" {
			sessionName = r.FormValue("session")
		}
		ua := r.Header.Get("User-Agent")
		isDSVideo := isDSVideoUA(ua)
		log.Printf("[WebAPI] Auth login session=%q isDSVideo=%v UA=%q", sessionName, isDSVideo, ua)
		if !isDSVideo && sessionName != "" && sessionName != "DSVideo" && sessionName != "VideoStation" {
			s.proxyAuthToAuthCGI(w, r)
			return
		}

		// Capture account from the request early (before any proxying).
		// Some DSM variants omit "account" in the login response, but DS Video expects it.
		_ = r.ParseForm()
		reqAccount := r.FormValue("account")
		if reqAccount == "" {
			reqAccount = r.FormValue("username")
		}
		if reqAccount == "" {
			reqAccount = r.FormValue("user")
		}

		// DS Video 3.4.5-380 in particular will crash if certain fields are missing
		// from the login response. We still rely on DSM to validate credentials
		// (including the RSA-encrypted password flow), but we normalize the response
		// payload to include the expected keys.
		status, hdr, body, err := s.proxyFormToDSM(r, "http://127.0.0.1:5000/webapi/entry.cgi")
		if err != nil {
			log.Printf("[WebAPI] Auth login proxy failed: %v", err)
			writeWebAPIError(w, 100)
			return
		}

		{
			// Never log Set-Cookie or the response body here. DSM's Set-Cookie carries
			// `id=<SID>` and the body carries {"sid":"..."} — and a DSM SID is a COMPLETE
			// credential in this system: getWebAPISession accepts it from a cookie, query
			// param, or form field, and validateDSMSession will mint a full JWT for anyone
			// who presents it. Anything that can read the package log (another DSM app, a
			// lower-privilege shell account, a support bundle the user emails) could replay
			// it and be signed in as that user, with no password.
			//
			// redactSensitiveParams does not cover this — it rewrites r.URL query params
			// only, not response headers or bodies. Log shape, never content.
			log.Printf("[WebAPI] Auth login DSM proxy response: status=%d bytes=%d set_cookie_count=%d",
				status, len(body), len(hdr.Values("Set-Cookie")))
		}

		var loginResult struct {
			Success bool           `json:"success"`
			Data    map[string]any `json:"data"`
			Error   any            `json:"error"`
		}
		if err := json.Unmarshal(body, &loginResult); err != nil {
			log.Printf("[WebAPI] Auth login proxy returned non-JSON: %v", err)
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(status)
			_, _ = w.Write(body)
			return
		}
		if !loginResult.Success {
			// Relay DSM's error response verbatim.
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(status)
			_, _ = w.Write(body)
			return
		}

		// Extract basics
		sid, _ := loginResult.Data["sid"].(string)
		did, _ := loginResult.Data["did"].(string)
		account, _ := loginResult.Data["account"].(string)
		if account == "" {
			// Some DSM versions may use different keys.
			if v, ok := loginResult.Data["username"].(string); ok && v != "" {
				account = v
				loginResult.Data["account"] = v
			} else if v, ok := loginResult.Data["user"].(string); ok && v != "" {
				account = v
				loginResult.Data["account"] = v
			}
		}
		if account == "" {
			// DSM v6 login response often omits "account"; DS Video expects it.
			account = r.FormValue("account")
			if account == "" {
				account = r.URL.Query().Get("account")
			}
			loginResult.Data["account"] = account
		}
		if account == "" && reqAccount != "" {
			account = reqAccount
			loginResult.Data["account"] = reqAccount
		}
		if account == "" && sid != "" {
			// Last resort: validate the newly issued SID against DSM to obtain the account.
			if u, err := s.validateDSMSession(sid); err == nil && u != "" {
				account = u
				loginResult.Data["account"] = u
			}
		}

		// Bind did -> account for Entry.Request.request to convert DSM's `id` cookie
		// into a local WebAPI session.
		if did != "" && account != "" {
			didToLoginBinding.Store(did, loginBinding{Username: account, CreatedAt: time.Now()})
		}

		// Fill in fields that older DS Video builds assume are present.
		if _, ok := loginResult.Data["is_portal_port"]; !ok {
			loginResult.Data["is_portal_port"] = false
		}
		if _, ok := loginResult.Data["expire_time"]; !ok {
			loginResult.Data["expire_time"] = 0
		}
		if _, ok := loginResult.Data["synotoken"]; !ok {
			// CSRF token used by some clients; DSM may omit for v6.
			loginResult.Data["synotoken"] = randID("")
		}
		if _, ok := loginResult.Data["ik_message"]; !ok {
			loginResult.Data["ik_message"] = ""
		}
		if _, ok := loginResult.Data["device_id"]; !ok {
			// DS Video 3.x sometimes uses device_id instead of did.
			if did != "" {
				loginResult.Data["device_id"] = did
			}
		}

		// Set cookies like DSM does. DS Video performs connectivity checks against
		// non-/webapi endpoints (e.g. /webman/pingpong.cgi) and expects the `id`
		// cookie to be sent there as well, so the Path must be "/".
		if sid != "" {
			http.SetCookie(w, &http.Cookie{
				Name:     "id",
				Value:    sid,
				Path:     "/",
				Expires:  time.Now().Add(7 * 24 * time.Hour),
				MaxAge:   7 * 24 * 60 * 60,
				HttpOnly: true,
			})
		}
		if did != "" {
			http.SetCookie(w, &http.Cookie{
				Name:     "did",
				Value:    did,
				Path:     "/",
				Expires:  time.Now().Add(365 * 24 * time.Hour),
				MaxAge:   365 * 24 * 60 * 60,
				HttpOnly: true,
			})
		}

		// Register a local session keyed by the DSM-issued SID so subsequent calls
		// to our VideoStation APIs can resolve mappings without extra DSM calls.
		stored := false
		if sid != "" && webAPISessions.Get(sid) == nil {
			// Even if DSM doesn't give us an account, we still need to accept the SID
			// immediately on the next request (DS Video will crash if SID validation
			// fails right after login). Use a deterministic fallback identity.
			username := account
			if username == "" {
				username = "sid_" + sid
			}
			userID := "u_" + sanitizeID(username)
			token, tokErr := s.issueToken(userID, username)
			if tokErr == nil {
				session := &WebAPISession{
					SID:       sid,
					UserID:    userID,
					Username:  username,
					Token:     token,
					DeviceID:  did,
					CreatedAt: time.Now(),
				}
				webAPISessions.mu.Lock()
				webAPISessions.sessions[sid] = session
				webAPISessions.mu.Unlock()
				go persistSession(s.db, session)
				stored = true
			} else {
				log.Printf("[WebAPI] Auth login: failed to issue token for %q (sid=%s...): %v",
					username, sid[:min(16, len(sid))], tokErr)
			}
		}
		log.Printf("[WebAPI] Auth login success: account=%q sid=%s... did_present=%v stored=%v",
			account, func() string {
				if len(sid) > 16 {
					return sid[:16]
				}
				return sid
			}(), did != "", stored)

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"success": true,
			"data":    loginResult.Data,
		})

	case "logout":
		session := s.getWebAPISession(r)
		if session != nil {
			// TASK-806: revoke the JWT embedded in this WebAPI session too, not just the
			// local SID. Without this the REST plane would keep honoring the same token
			// after a WebAPI logout — divergent revocation across the two session planes.
			s.revokeJWT(session.Token)
			webAPISessions.Delete(session.SID)
			deletePersistedSession(s.db, session.SID)
		}
		writeWebAPISuccess(w, map[string]any{})

	default:
		// Unknown method (synotoken, token, session, etc.) — let DSM handle it
		// so the web UI and other Synology apps get correct native responses.
		s.proxyAuthToAuthCGI(w, r)
	}
}

// -------------------------
// SYNO.VideoStation2.Info
// -------------------------

func (s *Server) handleWebAPIInfo(w http.ResponseWriter, r *http.Request, method string) {
	// DS Video app uses "get" or "getinfo".
	if method != "get" && method != "getinfo" {
		writeWebAPIError(w, 101)
		return
	}

	// Parse the session (optional for Info.get — some apps call it before full auth).
	session := s.getWebAPISession(r)
	sid := r.URL.Query().Get("_sid")
	if sid == "" {
		sid = r.FormValue("_sid")
	}
	log.Printf("[WebAPI] Info.get session=%v _sid_present=%v UA=%q",
		session != nil, sid != "", r.Header.Get("User-Agent"))

	// Return a superset of fields observed across Video Station builds.
	//
	// DS Video 3.4.5 is fragile (EXC_BREAKPOINT/SIGTRAP) and appears to assert if
	// certain keys are missing or have unexpected types. In particular, some builds
	// treat `version` as a numeric string and `version_string` as the human version
	// (e.g. "2.4.6-1594"). We provide both to avoid client-side parsing crashes.
	//
	// DS Video 3.x expects the home-section feature flag to be enabled and will
	// immediately query HomeSection.list after Info.get. We keep the home feed empty
	// (see handleWebAPIHomeSection) so the app can continue to Library.list without
	// requiring full Video Station home personalization logic.
	//
	// Extra fields we previously added (codectable, certificate, support_dolby_vision,
	// support_dts_passthrough, support_ac3_passthrough, prefer_mpeg4, support_blu_ray)
	// are NOT present in real 3.2.0-3028 captures and may cause Swift decoding panics.
	writeWebAPISuccess(w, map[string]any{
		// Versioning
		"version":        "3028",
		"version_string": "3.2.0-3028",

		// Core flags
		"is_manager":  true,
		"running":     true,
		"onlylive":    false,
		"enablecinema": false,

		// Codec / streaming flags
		"support_dolby": false,
		"support_ac3":   false,
		"support_dts":   false,
		"support_remux": true,
		"support_transcode":           false,
		"support_hardware_transcode":  false,
		"support_software_transcode":  false,
		"support_fhd_hardware_transcode": false,
		"support_dtv_transcode":          false,

		// UI / feature flags
		"home_section_enabled":       true,
		"is_dtv_enabled":             false,
		"is_subtitle_search_enabled": true,
		"support_appletv_os":         true,

		// Privileges (older VideoStation.Info payloads include this)
		"privilege": map[string]any{
			"dtv":                false,
			"offline_conversion":  false,
			"renderer":           true,
			"sharing":            true,
		},

		// Playback / metadata settings
		"metadata_mode":    2,
		"force_hls":        false,
		"subtitle_mode":    0,
		"default_library":  0,
		"watchstatus":      true,
		"watchstatus_keep": 30,
		"watchstatus_mode": 1,

		// Timezone info (VideoStation.Info payloads include this)
		"timezone":        "UTC",
		"timezone_offset": 0,
	})
}

// -------------------------
// SYNO.VideoStation2.Library
// -------------------------

func (s *Server) handleWebAPILibrary(w http.ResponseWriter, r *http.Request, method string) {
	if method != "list" {
		writeWebAPIError(w, 101)
		return
	}

	session := s.getWebAPISession(r)
	if session == nil {
		writeWebAPIError(w, 105) // Not logged in
		return
	}

	libraries := []map[string]any{
		{"id": 0, "name": "Movies", "type": "movie", "visible": true, "is_cross_library": false},
		{"id": 1, "name": "TV Shows", "type": "tvshow", "visible": true, "is_cross_library": false},
	}

	writeWebAPISuccess(w, map[string]any{
		"library": libraries,
		"total":   len(libraries),
	})
}

// -------------------------
// SYNO.VideoStation2.Movie
// -------------------------

func (s *Server) handleWebAPIMovie(w http.ResponseWriter, r *http.Request, method string) {
	session := s.getWebAPISession(r)
	if session == nil {
		writeWebAPIError(w, 105)
		return
	}

	switch method {
	case "list":
		s.webAPIMovieList(w, r, session)
	case "getinfo":
		s.webAPIMovieGetInfo(w, r, session)
	default:
		writeWebAPIError(w, 101)
	}
}

func (s *Server) webAPIMovieList(w http.ResponseWriter, r *http.Request, session *WebAPISession) {
	// r.FormValue reads from POST body OR URL query string (POST body takes precedence),
	// so it works correctly when the official DS Video app POSTs parameters in the body.
	limit := parseInt(r.FormValue("limit"), 50)
	if limit <= 0 || limit > 10000 {
		limit = 10000
	}
	offset := parseInt(r.FormValue("offset"), 0)
	sortBy := r.FormValue("sort_by")
	sortDir := r.FormValue("sort_direction")

	// Count total
	var total int
	s.db.QueryRow("SELECT COUNT(*) FROM items WHERE library_id = 'lib_movies'").Scan(&total)

	// Build ORDER BY
	orderClause := "ORDER BY title ASC"
	switch sortBy {
	case "title":
		orderClause = "ORDER BY title"
	case "date", "year":
		orderClause = "ORDER BY year"
	case "added_date":
		orderClause = "ORDER BY added_at"
	}
	if strings.EqualFold(sortDir, "desc") {
		orderClause += " DESC"
	} else if sortBy != "" {
		orderClause += " ASC"
	}

	rows, err := s.db.Query(`
		SELECT id, title, year, duration_seconds, rating, poster_path, backdrop_path,
		       overview, genres, original_title, content_rating, director, cast_names
		FROM items WHERE library_id = 'lib_movies'
		`+orderClause+` LIMIT ? OFFSET ?`, limit, offset)
	if err != nil {
		writeWebAPIError(w, 100)
		return
	}
	defer rows.Close()

	movies := make([]map[string]any, 0)
	movieIDTaken := make(map[int]string) // local collision tracker for this page

	for rows.Next() {
		var id, title string
		var year, duration sql.NullInt64
		var rating sql.NullFloat64
		var posterPath, backdropPath, overview, genres sql.NullString
		var originalTitle, contentRating, director, castNames sql.NullString

		if err := rows.Scan(&id, &title, &year, &duration, &rating,
			&posterPath, &backdropPath, &overview, &genres,
			&originalTitle, &contentRating, &director, &castNames); err != nil {
			continue
		}

		// Get watch status
		p, _ := s.getProgress(session.UserID, id)
		var watchStatus map[string]any
		if p != nil {
			pos, _ := p["positionSeconds"].(int)
			dur, _ := p["durationSeconds"].(int)
			watchStatus = map[string]any{
				"time":       pos,
				"total_time": dur,
			}
		}

		// Derive a stable mapper_id from the item's database ID (hash-based,
		// sort-order independent). Collision detection ensures uniqueness within
		// the current result page.
		mapperID := stableIDWithCollision(id, movieIDTaken)
		movieIDTaken[mapperID] = id

		movie := map[string]any{
			"id":        mapperID,
			"mapper_id": mapperID,
			"title":     title,
			"type":      "movie",
			// The official DS Video app uses file[0].id as the streaming file ID.
			// We set it to the same mapperID so streaming open resolves correctly.
			"file": []map[string]any{{"id": mapperID}},
		}

		if year.Valid {
			movie["original_available"] = fmt.Sprintf("%d", year.Int64)
			movie["year"] = int(year.Int64)
		}
		if duration.Valid {
			movie["duration"] = int(duration.Int64)
		}
		if rating.Valid {
			movie["rating"] = rating.Float64
		}
		if watchStatus != nil {
			movie["watch_status"] = watchStatus
		}
		// Store the internal ID as a tag for lookup
		movie["_internal_id"] = id

		movies = append(movies, movie)
	}

	// Store ID mapping for this session (mapper_id -> internal_id)
	s.storeIDMappings(session.SID, movies)

	// Remove internal IDs before sending
	for _, m := range movies {
		delete(m, "_internal_id")
	}

	writeWebAPISuccess(w, map[string]any{
		"total": total,
		"movie": movies,
	})
}

func (s *Server) webAPIMovieGetInfo(w http.ResponseWriter, r *http.Request, session *WebAPISession) {
	idStr := r.URL.Query().Get("id")
	if idStr == "" {
		idStr = r.FormValue("id")
	}

	// Resolve mapper_id to internal ID
	internalID := s.resolveMapperID(session.SID, idStr, "lib_movies")
	if internalID == "" {
		writeWebAPIError(w, 100)
		return
	}

	var id, title string
	var year, duration sql.NullInt64
	var rating sql.NullFloat64
	var posterPath, backdropPath, overview, genres sql.NullString
	var originalTitle, contentRating, director, castNames sql.NullString

	err := s.db.QueryRow(`
		SELECT id, title, year, duration_seconds, rating, poster_path, backdrop_path,
		       overview, genres, original_title, content_rating, director, cast_names
		FROM items WHERE id = ?`, internalID).Scan(
		&id, &title, &year, &duration, &rating,
		&posterPath, &backdropPath, &overview, &genres,
		&originalTitle, &contentRating, &director, &castNames)
	if err != nil {
		writeWebAPIError(w, 100)
		return
	}

	mapperID, _ := strconv.Atoi(idStr)

	movie := map[string]any{
		"id":        mapperID,
		"mapper_id": mapperID,
		"title":     title,
		"type":      "movie",
		"file":      []map[string]any{{"id": mapperID}},
	}

	if originalTitle.Valid {
		movie["original_title"] = originalTitle.String
	}
	if year.Valid {
		movie["original_available"] = fmt.Sprintf("%d", year.Int64)
		movie["year"] = int(year.Int64)
	}
	if duration.Valid {
		movie["duration"] = int(duration.Int64)
	}
	if contentRating.Valid {
		movie["rating"] = contentRating.String
	}
	if overview.Valid {
		movie["summary"] = overview.String
	}
	if genres.Valid && genres.String != "" {
		movie["genres"] = strings.Split(genres.String, ",")
	}
	if castNames.Valid && castNames.String != "" {
		actors := make([]map[string]any, 0)
		for _, name := range strings.Split(castNames.String, ",") {
			actors = append(actors, map[string]any{"name": strings.TrimSpace(name)})
		}
		movie["actors"] = actors
	}

	writeWebAPISuccess(w, map[string]any{
		"movie": []map[string]any{movie},
	})
}

// -------------------------
// SYNO.VideoStation2.TVShow
// -------------------------

func (s *Server) handleWebAPITVShow(w http.ResponseWriter, r *http.Request, method string) {
	session := s.getWebAPISession(r)
	if session == nil {
		writeWebAPIError(w, 105)
		return
	}

	switch method {
	case "list":
		s.webAPITVShowList(w, r, session)
	case "getinfo":
		s.webAPITVShowGetInfo(w, r, session)
	default:
		writeWebAPIError(w, 101)
	}
}

func (s *Server) webAPITVShowList(w http.ResponseWriter, r *http.Request, session *WebAPISession) {
	limit := parseInt(r.FormValue("limit"), 10000)
	if limit <= 0 || limit > 10000 {
		limit = 10000
	}
	offset := parseInt(r.FormValue("offset"), 0)

	tvRoot := filepath.Clean(s.cfg.TVPath) + "/"

	rows, err := s.db.Query(`
		SELECT id, path, show_name, year, rating, poster_path, backdrop_path, overview, genres
		FROM items WHERE library_id = 'lib_tv'`)
	if err != nil {
		writeWebAPIError(w, 100)
		return
	}
	defer rows.Close()

	type showInfo struct {
		folderName  string
		displayName string
		year        sql.NullInt64
		rating      sql.NullFloat64
		posterID    string
		overview    string
		genres      string
		count       int
	}

	showMap := map[string]*showInfo{}
	showOrder := []string{}

	for rows.Next() {
		var id, path string
		var showName sql.NullString
		var year sql.NullInt64
		var ratingVal sql.NullFloat64
		var posterPath, backdropPath, overview, genres sql.NullString

		if err := rows.Scan(&id, &path, &showName, &year, &ratingVal, &posterPath, &backdropPath, &overview, &genres); err != nil {
			continue
		}

		var folderName string
		rel := strings.TrimPrefix(path, tvRoot)
		parts := strings.SplitN(rel, "/", 2)
		if len(parts) > 1 {
			folderName = parts[0]
		} else {
			base := filepath.Base(path)
			folderName = strings.TrimSuffix(base, filepath.Ext(base))
		}
		if folderName == "" {
			continue
		}

		info, exists := showMap[folderName]
		if !exists {
			info = &showInfo{folderName: folderName, displayName: folderName}
			showMap[folderName] = info
			showOrder = append(showOrder, folderName)
		}

		if showName.Valid && showName.String != "" && info.displayName == info.folderName {
			info.displayName = showName.String
		}
		info.count++
		if year.Valid && (!info.year.Valid || year.Int64 < info.year.Int64) {
			info.year = year
		}
		if ratingVal.Valid && (!info.rating.Valid || ratingVal.Float64 > info.rating.Float64) {
			info.rating = ratingVal
		}
		if posterPath.Valid && posterPath.String != "" && info.posterID == "" {
			info.posterID = id
		}
		if overview.Valid && overview.String != "" && info.overview == "" {
			info.overview = overview.String
		}
		if genres.Valid && genres.String != "" && info.genres == "" {
			info.genres = genres.String
		}
	}

	// Sort alphabetically
	for i := 0; i < len(showOrder); i++ {
		for j := i + 1; j < len(showOrder); j++ {
			if strings.ToLower(showMap[showOrder[i]].displayName) > strings.ToLower(showMap[showOrder[j]].displayName) {
				showOrder[i], showOrder[j] = showOrder[j], showOrder[i]
			}
		}
	}

	total := len(showOrder)

	// Apply pagination
	if offset >= len(showOrder) {
		writeWebAPISuccess(w, map[string]any{"total": total, "tvshow": []any{}})
		return
	}
	end := offset + limit
	if end > len(showOrder) {
		end = len(showOrder)
	}
	page := showOrder[offset:end]

	showIDTaken := make(map[int]string) // local collision tracker for this page
	shows := make([]map[string]any, 0, len(page))
	for _, key := range page {
		info := showMap[key]
		// Derive stable mapper_id from the folder name (the natural TV show key).
		mapperID := stableIDWithCollision(key, showIDTaken)
		showIDTaken[mapperID] = key
		show := map[string]any{
			"id":        mapperID,
			"mapper_id": mapperID,
			"title":     info.displayName,
			"type":      "tvshow",
		}
		if info.year.Valid {
			show["original_available"] = fmt.Sprintf("%d", info.year.Int64)
			show["year"] = int(info.year.Int64)
		}
		if info.rating.Valid {
			show["rating"] = info.rating.Float64
		}
		if info.overview != "" {
			show["summary"] = info.overview
		}
		// Store folder name for episode lookup
		show["_folder_name"] = info.folderName
		show["_poster_id"] = info.posterID
		shows = append(shows, show)
	}

	// Store mappings for TV shows
	s.storeTVShowMappings(session.SID, shows)

	// Clean internal fields
	for _, sh := range shows {
		delete(sh, "_folder_name")
		delete(sh, "_poster_id")
	}

	writeWebAPISuccess(w, map[string]any{
		"total":  total,
		"tvshow": shows,
	})
}

func (s *Server) webAPITVShowGetInfo(w http.ResponseWriter, r *http.Request, session *WebAPISession) {
	idStr := r.URL.Query().Get("id")
	if idStr == "" {
		idStr = r.FormValue("id")
	}

	folderName := s.resolveTVShowFolder(session.SID, idStr)
	if folderName == "" {
		writeWebAPIError(w, 100)
		return
	}

	tvRoot := filepath.Clean(s.cfg.TVPath) + "/"
	folderPrefix := tvRoot + folderName + "/"

	// Get show metadata
	var year sql.NullInt64
	var ratingVal sql.NullFloat64
	var overview, genres, showNameDB sql.NullString
	s.db.QueryRow(`
		SELECT MAX(year), MAX(rating), MAX(overview), MAX(genres), MAX(show_name)
		FROM items WHERE (path LIKE ? OR show_name = ?) AND library_id = 'lib_tv'`,
		folderPrefix+"%", folderName).Scan(&year, &ratingVal, &overview, &genres, &showNameDB)

	displayName := folderName
	if showNameDB.Valid && showNameDB.String != "" {
		displayName = showNameDB.String
	}

	mapperID, _ := strconv.Atoi(idStr)

	show := map[string]any{
		"id":        mapperID,
		"mapper_id": mapperID,
		"title":     displayName,
		"type":      "tvshow",
	}
	if year.Valid {
		show["year"] = int(year.Int64)
	}
	if ratingVal.Valid {
		show["rating"] = ratingVal.Float64
	}
	if overview.Valid {
		show["summary"] = overview.String
	}
	if genres.Valid && genres.String != "" {
		show["genres"] = strings.Split(genres.String, ",")
	}

	writeWebAPISuccess(w, map[string]any{
		"tvshow": []map[string]any{show},
	})
}

// -------------------------
// SYNO.VideoStation2.TVShowEpisode
// -------------------------

func (s *Server) handleWebAPITVShowEpisode(w http.ResponseWriter, r *http.Request, method string) {
	session := s.getWebAPISession(r)
	if session == nil {
		writeWebAPIError(w, 105)
		return
	}

	switch method {
	case "list":
		s.webAPITVShowEpisodeList(w, r, session)
	case "getinfo":
		s.webAPITVShowEpisodeGetInfo(w, r, session)
	default:
		writeWebAPIError(w, 101)
	}
}

func (s *Server) webAPITVShowEpisodeList(w http.ResponseWriter, r *http.Request, session *WebAPISession) {
	// Can be filtered by tvshow_id (mapper_id of the show)
	tvshowIDStr := r.URL.Query().Get("tvshow_id")
	if tvshowIDStr == "" {
		tvshowIDStr = r.FormValue("tvshow_id")
	}

	limit := parseInt(r.FormValue("limit"), 10000)
	offset := parseInt(r.FormValue("offset"), 0)

	var folderName string
	if tvshowIDStr != "" {
		folderName = s.resolveTVShowFolder(session.SID, tvshowIDStr)
	}

	tvRoot := filepath.Clean(s.cfg.TVPath) + "/"

	var rows *sql.Rows
	var err error
	if folderName != "" {
		folderPrefix := tvRoot + folderName + "/"
		rows, err = s.db.Query(`
			SELECT id, title, season_number, episode_number, episode_title,
			       duration_seconds, year, rating, poster_path, show_name
			FROM items
			WHERE (path LIKE ? OR show_name = ?) AND library_id = 'lib_tv'
			ORDER BY COALESCE(season_number, 0), COALESCE(episode_number, 0)
			LIMIT ? OFFSET ?`,
			folderPrefix+"%", folderName, limit, offset)
	} else {
		rows, err = s.db.Query(`
			SELECT id, title, season_number, episode_number, episode_title,
			       duration_seconds, year, rating, poster_path, show_name
			FROM items WHERE library_id = 'lib_tv'
			ORDER BY title ASC
			LIMIT ? OFFSET ?`, limit, offset)
	}
	if err != nil {
		writeWebAPIError(w, 100)
		return
	}
	defer rows.Close()

	episodes := make([]map[string]any, 0)
	epIDTaken := make(map[int]string) // local collision tracker for this page

	for rows.Next() {
		var id, title string
		var seasonNum, episodeNum, duration, year sql.NullInt64
		var ratingVal sql.NullFloat64
		var epTitle, posterPath, showName sql.NullString

		if err := rows.Scan(&id, &title, &seasonNum, &episodeNum, &epTitle,
			&duration, &year, &ratingVal, &posterPath, &showName); err != nil {
			continue
		}

		// Get watch status
		p, _ := s.getProgress(session.UserID, id)
		var watchStatus map[string]any
		if p != nil {
			pos, _ := p["positionSeconds"].(int)
			dur, _ := p["durationSeconds"].(int)
			watchStatus = map[string]any{
				"time":       pos,
				"total_time": dur,
			}
		}

		// Stable mapper_id derived from the episode's database ID.
		mapperID := stableIDWithCollision(id, epIDTaken)
		epIDTaken[mapperID] = id

		ep := map[string]any{
			"id":        mapperID,
			"mapper_id": mapperID,
			"title":     title,
			"type":      "tvshow_episode",
			"file":      []map[string]any{{"id": mapperID}},
		}

		if epTitle.Valid && epTitle.String != "" {
			ep["tagline"] = epTitle.String
		}
		if seasonNum.Valid {
			ep["season"] = int(seasonNum.Int64)
		}
		if episodeNum.Valid {
			ep["episode"] = int(episodeNum.Int64)
		}
		if duration.Valid {
			ep["duration"] = int(duration.Int64)
		}
		if watchStatus != nil {
			ep["watch_status"] = watchStatus
		}
		ep["_internal_id"] = id

		episodes = append(episodes, ep)
	}

	// Store mappings
	s.storeIDMappings(session.SID, episodes)

	// Count total
	var total int
	if folderName != "" {
		folderPrefix := tvRoot + folderName + "/"
		s.db.QueryRow("SELECT COUNT(*) FROM items WHERE (path LIKE ? OR show_name = ?) AND library_id = 'lib_tv'",
			folderPrefix+"%", folderName).Scan(&total)
	} else {
		s.db.QueryRow("SELECT COUNT(*) FROM items WHERE library_id = 'lib_tv'").Scan(&total)
	}

	// Clean internal fields
	for _, ep := range episodes {
		delete(ep, "_internal_id")
	}

	writeWebAPISuccess(w, map[string]any{
		"total":          total,
		"tvshow_episode": episodes,
	})
}

func (s *Server) webAPITVShowEpisodeGetInfo(w http.ResponseWriter, r *http.Request, session *WebAPISession) {
	idStr := r.URL.Query().Get("id")
	if idStr == "" {
		idStr = r.FormValue("id")
	}

	internalID := s.resolveMapperID(session.SID, idStr, "lib_tv")
	if internalID == "" {
		writeWebAPIError(w, 100)
		return
	}

	var id, title string
	var seasonNum, episodeNum, duration sql.NullInt64
	var epTitle, showName, overview, posterPath sql.NullString

	err := s.db.QueryRow(`
		SELECT id, title, season_number, episode_number, episode_title,
		       duration_seconds, show_name, overview, poster_path
		FROM items WHERE id = ?`, internalID).Scan(
		&id, &title, &seasonNum, &episodeNum, &epTitle,
		&duration, &showName, &overview, &posterPath)
	if err != nil {
		writeWebAPIError(w, 100)
		return
	}

	mapperID, _ := strconv.Atoi(idStr)

	ep := map[string]any{
		"id":        mapperID,
		"mapper_id": mapperID,
		"title":     title,
		"type":      "tvshow_episode",
		"file":      []map[string]any{{"id": mapperID}},
	}
	if epTitle.Valid {
		ep["tagline"] = epTitle.String
	}
	if seasonNum.Valid {
		ep["season"] = int(seasonNum.Int64)
	}
	if episodeNum.Valid {
		ep["episode"] = int(episodeNum.Int64)
	}
	if duration.Valid {
		ep["duration"] = int(duration.Int64)
	}
	if overview.Valid {
		ep["summary"] = overview.String
	}

	writeWebAPISuccess(w, map[string]any{
		"tvshow_episode": []map[string]any{ep},
	})
}

// -------------------------
// SYNO.VideoStation2.Streaming
// -------------------------

func (s *Server) handleWebAPIStreaming(w http.ResponseWriter, r *http.Request, method string) {
	session := s.getWebAPISession(r)
	if session == nil {
		writeWebAPIError(w, 105)
		return
	}

	switch method {
	case "open":
		s.webAPIStreamingOpen(w, r, session)
	case "close":
		s.webAPIStreamingClose(w, r, session)
	default:
		writeWebAPIError(w, 101)
	}
}

func (s *Server) webAPIStreamingOpen(w http.ResponseWriter, r *http.Request, session *WebAPISession) {
	// The file parameter can be JSON: {"id": N} or {"id": N, "library_id": 0}
	fileParam := r.URL.Query().Get("file")
	if fileParam == "" {
		fileParam = r.FormValue("file")
	}

	var itemMapperID int
	if fileParam != "" {
		// Parse JSON file parameter
		var fileData struct {
			ID        int `json:"id"`
			LibraryID int `json:"library_id"`
		}
		if err := json.Unmarshal([]byte(fileParam), &fileData); err == nil {
			itemMapperID = fileData.ID
		}
	}

	if itemMapperID == 0 {
		// Try id parameter directly
		idStr := r.URL.Query().Get("id")
		if idStr == "" {
			idStr = r.FormValue("id")
		}
		itemMapperID, _ = strconv.Atoi(idStr)
	}

	if itemMapperID == 0 {
		writeWebAPIError(w, 101)
		return
	}

	// Resolve mapper_id to internal ID (try movies first, then TV)
	internalID := s.resolveMapperID(session.SID, strconv.Itoa(itemMapperID), "lib_movies")
	if internalID == "" {
		internalID = s.resolveMapperID(session.SID, strconv.Itoa(itemMapperID), "lib_tv")
	}
	if internalID == "" {
		log.Printf("[WebAPI] Streaming open: cannot resolve mapper_id %d", itemMapperID)
		writeWebAPIError(w, 1101) // File not found
		return
	}

	// Create playback session (reuse existing handlePlayback logic)
	var path string
	err := s.db.QueryRow("SELECT path FROM items WHERE id = ?", internalID).Scan(&path)
	if err != nil {
		writeWebAPIError(w, 1101)
		return
	}

	// Create a direct play session (the iOS app handles format via AVPlayer)
	sessionID := randID("vs_")
	ps := PlaySession{
		ItemID:       internalID,
		Path:         path,
		Kind:         "direct",
		CreatedAt:    time.Now(),
		LastAccess:   time.Now(), // TASK-794: seed so the idle reaper doesn't evict before first GET
		PlaybackMode: 0,          // DirectPlay
	}

	s.mu.Lock()
	s.playSessions[sessionID] = ps
	s.mu.Unlock()

	log.Printf("[WebAPI] Stream opened: mapper_id=%d -> internal=%s, session=%s", itemMapperID, internalID, sessionID)

	writeWebAPISuccess(w, map[string]any{
		"stream_id": sessionID,
		"format":    "raw",
	})
}

func (s *Server) webAPIStreamingClose(w http.ResponseWriter, r *http.Request, session *WebAPISession) {
	streamID := r.URL.Query().Get("id")
	if streamID == "" {
		streamID = r.FormValue("id")
	}

	if streamID != "" {
		s.mu.Lock()
		delete(s.playSessions, streamID)
		s.mu.Unlock()
	}

	writeWebAPISuccess(w, map[string]any{})
}

// handleWebAPIVTEStreaming handles the video streaming endpoint.
// GET /webapi/VideoStation/vtestreaming.cgi/DTV.mov?api=SYNO.VideoStation.Streaming&method=stream&id=<stream_id>&format=raw
func (s *Server) handleWebAPIVTEStreaming(w http.ResponseWriter, r *http.Request) {
	streamID := r.URL.Query().Get("id")
	if streamID == "" {
		writeWebAPIError(w, 101)
		return
	}

	// Validate session from _sid or Cookie
	session := s.getWebAPISession(r)
	if session == nil {
		writeWebAPIError(w, 105)
		return
	}

	// TASK-794: read through getSession() (NOT a direct map read) so LastAccess is
	// bumped on every Range re-request. The 30-min idle playSessions reaper keys off
	// LastAccess; a direct RLock read left it pinned at CreatedAt, so a title longer
	// than 30 min was evicted mid-play and a post-30-min seek returned error 1101.
	ps, ok := s.getSession(streamID)
	if !ok {
		writeWebAPIError(w, 1101)
		return
	}

	// Serve the video file directly (the iOS app uses AVPlayer which handles seeking via Range headers)
	log.Printf("[WebAPI] Streaming file: %s", ps.Path)
	http.ServeFile(w, r, ps.Path)
}

// handleWebAPIVTEStreamingOpen handles POST to vtestreaming.cgi (the "open" call).
// The official app POSTs to this endpoint to get a stream_id before GETting the video.
func (s *Server) handleWebAPIVTEStreamingOpen(w http.ResponseWriter, r *http.Request) {
	session := s.getWebAPISession(r)
	if session == nil {
		writeWebAPIError(w, 105)
		return
	}

	method := r.FormValue("method")
	if method == "" {
		method = r.URL.Query().Get("method")
	}

	switch method {
	case "open":
		s.webAPIStreamingOpen(w, r, session)
	case "close":
		s.webAPIStreamingClose(w, r, session)
	default:
		// Default to open for POST requests
		s.webAPIStreamingOpen(w, r, session)
	}
}

// -------------------------
// SYNO.VideoStation2.Poster / SYNO.VideoStation.Poster
// -------------------------

func (s *Server) handleWebAPIPoster(w http.ResponseWriter, r *http.Request, method string) {
	if method != "get" && method != "getimage" {
		writeWebAPIError(w, 101)
		return
	}

	// Poster requests may or may not have session (official app sometimes skips _sid for posters)
	idStr := r.URL.Query().Get("id")
	if idStr == "" {
		idStr = r.FormValue("id")
	}
	itemType := r.URL.Query().Get("type") // "movie", "tvshow", "tvshow_episode"

	session := s.getWebAPISession(r)

	// TASK-804: poster.cgi was registered unauthenticated and, with no session, fell
	// through to a raw `SELECT 1 FROM items WHERE id = ?` that served the poster on a hit
	// and 404'd on a miss. Since item IDs are deterministic (hex-of-path), that let an
	// unauthenticated caller enumerate/guess IDs and distinguish existing items (200) from
	// non-existing (404) — a library-content-existence oracle. Require a valid session so
	// both the session-scoped mapper lookups AND the direct-ID fallback are auth-gated;
	// an unauthenticated request now always returns the same 105 regardless of ID.
	if session == nil {
		writeWebAPIError(w, 105)
		return
	}

	// Resolve the ID to internal ID
	var internalID string
	switch itemType {
	case "tvshow", "tvshow_episode":
		internalID = s.resolveMapperID(session.SID, idStr, "lib_tv")
		if internalID == "" {
			// Try poster ID from TV show mapping
			internalID = s.resolvePosterID(session.SID, idStr)
		}
	default:
		internalID = s.resolveMapperID(session.SID, idStr, "lib_movies")
	}

	if internalID == "" {
		// Fallback: try treating the ID as a direct item ID (now behind the session gate).
		var exists int
		err := s.db.QueryRow("SELECT 1 FROM items WHERE id = ?", idStr).Scan(&exists)
		if err == nil {
			internalID = idStr
		}
	}

	if internalID == "" {
		// No matching item - return 404 as empty image
		w.WriteHeader(http.StatusNotFound)
		return
	}

	// Get poster path for this item
	var posterPath sql.NullString
	s.db.QueryRow("SELECT poster_path FROM items WHERE id = ?", internalID).Scan(&posterPath)

	if !posterPath.Valid || posterPath.String == "" {
		w.WriteHeader(http.StatusNotFound)
		return
	}

	// Serve the cached image
	if s.imageCache == nil {
		w.WriteHeader(http.StatusNotFound)
		return
	}

	cached, err := s.imageCache.GetOrCacheTMDbImage(r.Context(), posterPath.String, metadata.ImageTypePoster, metadata.ImageSizeW500)
	if err != nil {
		log.Printf("[WebAPI] Poster cache error for %s: %v", internalID, err)
		w.WriteHeader(http.StatusNotFound)
		return
	}

	http.ServeFile(w, r, cached)
}

// handleWebAPIPosterCGI handles the dedicated poster.cgi endpoint.
// GET /webapi/VideoStation/poster.cgi?api=SYNO.VideoStation.Poster&method=getimage&version=3&id=<id>&type=movie
func (s *Server) handleWebAPIPosterCGI(w http.ResponseWriter, r *http.Request) {
	s.handleWebAPIPoster(w, r, "getimage")
}

// -------------------------
// SYNO.VideoStation.Backdrop
// -------------------------

func (s *Server) handleWebAPIBackdrop(w http.ResponseWriter, r *http.Request, method string) {
	if method != "get" {
		writeWebAPIError(w, 101)
		return
	}

	mapperIDStr := r.URL.Query().Get("mapper_id")
	if mapperIDStr == "" {
		mapperIDStr = r.FormValue("mapper_id")
	}

	session := s.getWebAPISession(r)
	if session == nil {
		writeWebAPIError(w, 105)
		return
	}

	// Resolve mapper_id to internal ID
	internalID := s.resolveMapperID(session.SID, mapperIDStr, "lib_movies")
	if internalID == "" {
		internalID = s.resolveMapperID(session.SID, mapperIDStr, "lib_tv")
	}

	if internalID == "" {
		w.WriteHeader(http.StatusNotFound)
		return
	}

	var backdropPath sql.NullString
	s.db.QueryRow("SELECT backdrop_path FROM items WHERE id = ?", internalID).Scan(&backdropPath)

	if !backdropPath.Valid || backdropPath.String == "" {
		w.WriteHeader(http.StatusNotFound)
		return
	}

	if s.imageCache == nil {
		w.WriteHeader(http.StatusNotFound)
		return
	}

	cached, err := s.imageCache.GetOrCacheTMDbImage(r.Context(), backdropPath.String, metadata.ImageTypeBackdrop, metadata.ImageSizeOriginal)
	if err != nil {
		w.WriteHeader(http.StatusNotFound)
		return
	}

	http.ServeFile(w, r, cached)
}

// -------------------------
// SYNO.VideoStation2.WatchStatus
// -------------------------

func (s *Server) handleWebAPIWatchStatus(w http.ResponseWriter, r *http.Request, method string) {
	session := s.getWebAPISession(r)
	if session == nil {
		writeWebAPIError(w, 105)
		return
	}

	if method != "update" {
		writeWebAPIError(w, 101)
		return
	}

	idStr := r.URL.Query().Get("id")
	if idStr == "" {
		idStr = r.FormValue("id")
	}
	timeStr := r.URL.Query().Get("time")
	if timeStr == "" {
		timeStr = r.FormValue("time")
	}
	totalTimeStr := r.URL.Query().Get("total_time")
	if totalTimeStr == "" {
		totalTimeStr = r.FormValue("total_time")
	}

	// Resolve mapper_id
	internalID := s.resolveMapperID(session.SID, idStr, "lib_movies")
	if internalID == "" {
		internalID = s.resolveMapperID(session.SID, idStr, "lib_tv")
	}
	if internalID == "" {
		writeWebAPIError(w, 100)
		return
	}

	position, _ := strconv.Atoi(timeStr)
	totalDuration, _ := strconv.Atoi(totalTimeStr)

	// Update progress in database
	now := time.Now().UTC().Format(time.RFC3339)
	_, err := s.db.Exec(`
		INSERT INTO progress (item_id, user_id, position_seconds, duration_seconds, updated_at)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(item_id, user_id) DO UPDATE SET
			position_seconds = excluded.position_seconds,
			duration_seconds = excluded.duration_seconds,
			updated_at = excluded.updated_at`,
		internalID, session.UserID, position, totalDuration, now)

	if err != nil {
		writeWebAPIError(w, 100)
		return
	}

	writeWebAPISuccess(w, map[string]any{})
}

// -------------------------
// SYNO.VideoStation2.File
// -------------------------

func (s *Server) handleWebAPIFile(w http.ResponseWriter, r *http.Request, method string) {
	session := s.getWebAPISession(r)
	if session == nil {
		writeWebAPIError(w, 105)
		return
	}

	switch method {
	case "getinfo":
		writeWebAPISuccess(w, map[string]any{})
	case "set_watchstatus":
		// Same as WatchStatus.update
		s.handleWebAPIWatchStatus(w, r, "update")
	default:
		writeWebAPIError(w, 101)
	}
}

// -------------------------
// SYNO.VideoStation2.HomeSection
// -------------------------

func (s *Server) handleWebAPIHomeSection(w http.ResponseWriter, r *http.Request, method string) {
	// DS Video 3.x calls HomeSection.list to populate the home screen feed
	// (recently added, continue watching, etc.). We return an empty section list
	// so the home screen loads cleanly without content rather than crashing.
	if method != "list" {
		writeWebAPIError(w, 101)
		return
	}
	session := s.getWebAPISession(r)
	if session == nil {
		writeWebAPIError(w, 105)
		return
	}
	writeWebAPISuccess(w, map[string]any{
		"section": []any{},
		"total":   0,
	})
}

// -------------------------
// Stable ID Generation
// -------------------------
// stableID derives a deterministic positive integer from a NAS item's natural
// key (e.g. its database ID or folder name) using FNV-32a. The lower 28 bits
// are used so the result fits in a positive int32, giving ~268 million slots
// which is far more than any realistic library size.
//
// stableIDWithCollision takes an already-occupied set and increments by 1
// until a free slot is found. For libraries under 100K items, FNV-32a
// collision probability is negligible (~1 in 4 billion per pair), so the
// loop almost never executes more than once.
func stableID(nasKey string) int {
	h := fnv.New32a()
	h.Write([]byte(nasKey))
	return int(h.Sum32()&0x0FFFFFFF) + 1 // +1 ensures non-zero
}

func stableIDWithCollision(nasKey string, taken map[int]string) int {
	id := stableID(nasKey)
	for {
		if existing, conflict := taken[id]; !conflict || existing == nasKey {
			return id
		}
		id++
		if id > 0x0FFFFFFF+1 {
			id = 1 // wrap around (extremely unlikely)
		}
	}
}

// -------------------------
// ID Mapping Storage
// -------------------------
// The Video Station API uses numeric IDs (mapper_id) while our internal
// storage uses string IDs. We maintain per-session mappings.

type idMapping struct {
	mu        sync.RWMutex
	movieIDs  map[string]string // mapper_id_str -> internal_id
	tvIDs     map[string]string // mapper_id_str -> internal_id
	tvShows   map[string]string // mapper_id_str -> folder_name
	posterIDs map[string]string // mapper_id_str -> poster internal_id
	// Reverse maps for collision detection: numeric_id -> nasKey
	// nasKey is items.id for movies/episodes, folderName for TV shows.
	movieTaken   map[int]string
	tvTaken      map[int]string
	tvShowTaken  map[int]string
	lastAccessed time.Time
}

var (
	idMappingsMu sync.RWMutex
	idMappings   = map[string]*idMapping{} // session_sid -> mapping
)

func getOrCreateMapping(sid string) *idMapping {
	idMappingsMu.Lock()
	defer idMappingsMu.Unlock()
	if m, ok := idMappings[sid]; ok {
		m.lastAccessed = time.Now()
		return m
	}
	m := &idMapping{
		movieIDs:     make(map[string]string),
		tvIDs:        make(map[string]string),
		tvShows:      make(map[string]string),
		posterIDs:    make(map[string]string),
		movieTaken:   make(map[int]string),
		tvTaken:      make(map[int]string),
		tvShowTaken:  make(map[int]string),
		lastAccessed: time.Now(),
	}
	idMappings[sid] = m
	return m
}

// cleanupExpiredIDMappings removes per-session ID mappings that have not been
// accessed within maxAge. Because these are purely session-scoped caches
// (mapper_id -> internal_id) they are safe to evict; the next request will
// simply re-populate them on demand.
// Returns the number of mappings evicted.
func cleanupExpiredIDMappings(maxAge time.Duration) int {
	cutoff := time.Now().Add(-maxAge)
	idMappingsMu.Lock()
	defer idMappingsMu.Unlock()
	evicted := 0
	for sid, m := range idMappings {
		if m.lastAccessed.Before(cutoff) {
			delete(idMappings, sid)
			evicted++
		}
	}
	if len(idMappings) > 100_000 {
		log.Printf("[WebAPI] WARNING: idMappings still holds %d entries after cleanup — possible leak", len(idMappings))
	}
	return evicted
}

func (s *Server) storeIDMappings(sid string, items []map[string]any) {
	m := getOrCreateMapping(sid)
	m.mu.Lock()
	defer m.mu.Unlock()

	for _, item := range items {
		internalID, _ := item["_internal_id"].(string)
		if internalID == "" {
			continue
		}
		mapperID := 0
		switch v := item["mapper_id"].(type) {
		case int:
			mapperID = v
		case float64:
			mapperID = int(v)
		}
		if mapperID == 0 {
			continue
		}

		key := strconv.Itoa(mapperID)
		itemType, _ := item["type"].(string)
		if itemType == "tvshow_episode" {
			m.tvIDs[key] = internalID
			m.tvTaken[mapperID] = internalID
		} else {
			m.movieIDs[key] = internalID
			m.movieTaken[mapperID] = internalID
		}
	}
}

func (s *Server) storeTVShowMappings(sid string, shows []map[string]any) {
	m := getOrCreateMapping(sid)
	m.mu.Lock()
	defer m.mu.Unlock()

	for _, show := range shows {
		mapperID := 0
		switch v := show["mapper_id"].(type) {
		case int:
			mapperID = v
		case float64:
			mapperID = int(v)
		}
		if mapperID == 0 {
			continue
		}
		key := strconv.Itoa(mapperID)
		if folderName, ok := show["_folder_name"].(string); ok {
			m.tvShows[key] = folderName
			m.tvShowTaken[mapperID] = folderName
		}
		if posterID, ok := show["_poster_id"].(string); ok && posterID != "" {
			m.posterIDs[key] = posterID
		}
	}
}

func (s *Server) resolveMapperID(sid, mapperIDStr, libraryID string) string {
	m := getOrCreateMapping(sid)
	m.mu.RLock()
	defer m.mu.RUnlock()

	switch libraryID {
	case "lib_movies":
		if id, ok := m.movieIDs[mapperIDStr]; ok {
			return id
		}
	case "lib_tv":
		if id, ok := m.tvIDs[mapperIDStr]; ok {
			return id
		}
	}

	// Fallback: try all maps
	if id, ok := m.movieIDs[mapperIDStr]; ok {
		return id
	}
	if id, ok := m.tvIDs[mapperIDStr]; ok {
		return id
	}

	return ""
}

func (s *Server) resolveTVShowFolder(sid, mapperIDStr string) string {
	m := getOrCreateMapping(sid)
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.tvShows[mapperIDStr]
}

func (s *Server) resolvePosterID(sid, mapperIDStr string) string {
	m := getOrCreateMapping(sid)
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.posterIDs[mapperIDStr]
}
