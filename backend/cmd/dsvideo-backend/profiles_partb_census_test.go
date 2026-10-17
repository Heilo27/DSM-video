package main

// TASK-916 part B, remaining ACs: AC-002-25 (watchlist half), AC-002-26 (FR-207), FR-216
// otp_required, FR-204 owner display name, and the FR-250 route census.

import (
	"context"
	"net/http"
	"os"
	"regexp"
	"sort"
	"strings"
	"testing"

	"github.com/go-chi/chi/v5"
)

// ── AC-002-25 (watchlist half) ──────────────────────────────────────────────────────────

func TestAC00225_WatchlistAddAboveCeilingIs403AndStoresNothing(t *testing.T) {
	// given: a level-1 profile, a G title, an R title and an unrated title
	e := newQAEnv(t)
	e.setOwnerPin(qaAlice, "0420")
	kid := e.mustCreate(qaAlice, "0420", "Kid", 1, nil)
	e.seedItem("wlG", "Family", sp("G"))
	e.seedItem("wlR", "Horror", sp("R"))
	e.seedItem("wlU", "Drama", nil)
	// when/then: R and unrated are refused and leave no row; G is stored
	for _, id := range []string{"wlR", "wlU"} {
		wantErr(t, e.do(qaAlice, "POST", "/watchlist/"+id, "", kid), 403, "content_restricted")
		if n := e.count(`SELECT COUNT(*) FROM watchlist WHERE item_id=?`, id); n != 0 {
			t.Errorf("%s: refused add still stored %d watchlist rows", id, n)
		}
	}
	wantOK(t, e.do(qaAlice, "POST", "/watchlist/wlG", "", kid), 200)
	if n := e.count(`SELECT COUNT(*) FROM watchlist WHERE item_id='wlG' AND profile_id=?`, kid); n != 1 {
		t.Errorf("G add stored %d rows under the kid, want 1", n)
	}
	if n := e.count(`SELECT COUNT(*) FROM watchlist`); n != 1 {
		t.Errorf("watchlist has %d rows in total, want exactly the G one", n)
	}
}

// ── AC-002-26 (FR-207) ──────────────────────────────────────────────────────────────────

func TestAC00226_LoweringTheCeilingHidesEntriesAndRaisingItBringsThemBackUnchanged(t *testing.T) {
	// given: a level-3 profile with progress (77s) and a watchlist entry on a PG-13 title,
	// plus a G control title that must stay visible throughout
	e := newQAEnv(t)
	e.setOwnerPin(qaAlice, "0420")
	teen := e.mustCreate(qaAlice, "0420", "Teen", 3, nil)
	e.seedItem("pg13", "Action", sp("PG-13"))
	e.seedItem("gctl", "Family", sp("G"))
	for _, id := range []string{"pg13", "gctl"} {
		wantOK(t, e.do(qaAlice, "POST", "/items/"+id+"/progress", jb(map[string]any{"positionSeconds": 77, "durationSeconds": 900}), teen), 200)
		wantOK(t, e.do(qaAlice, "POST", "/watchlist/"+id, "", teen), 200)
	}
	seen := func() (wl, pr map[string]bool, pos float64) {
		wl, pr = map[string]bool{}, map[string]bool{}
		for id := range idsOf(t, e.do(qaAlice, "GET", "/watchlist", "", teen), "items") {
			wl[id] = true
		}
		p := e.do(qaAlice, "GET", "/progress/all", "", teen).js["progress"].(map[string]any)
		for id, v := range p {
			pr[id] = true
			if id == "pg13" {
				pos = v.(map[string]any)["positionSeconds"].(float64)
			}
		}
		return
	}
	if wl, pr, pos := seen(); !wl["pg13"] || !pr["pg13"] || pos != 77 {
		t.Fatalf("precondition: level-3 profile must see its PG-13 entries, wl=%v pr=%v pos=%v", wl, pr, pos)
	}
	// when: lowered to level 1
	wantOK(t, e.do(qaAlice, "PATCH", "/profiles/"+teen, jb(map[string]any{"ownerPin": "0420", "maxAgeLevel": 1}), ""), 200)
	// then: hidden from both reads, control still there, rows NOT deleted
	wl, pr, _ := seen()
	if wl["pg13"] || pr["pg13"] || !wl["gctl"] || !pr["gctl"] {
		t.Errorf("after lowering: watchlist=%v progress=%v, want pg13 hidden and gctl shown", wl, pr)
	}
	if n := e.count(`SELECT COUNT(*) FROM watchlist WHERE item_id='pg13' AND profile_id=?`, teen) +
		e.count(`SELECT COUNT(*) FROM progress WHERE item_id='pg13' AND profile_id=? AND position_seconds=77`, teen); n != 2 {
		t.Errorf("lowering deleted rows: %d of 2 pg13 rows remain", n)
	}
	// when: raised back to 3
	wantOK(t, e.do(qaAlice, "PATCH", "/profiles/"+teen, jb(map[string]any{"ownerPin": "0420", "maxAgeLevel": 3}), ""), 200)
	// then: back, unchanged
	if wl, pr, pos := seen(); !wl["pg13"] || !pr["pg13"] || pos != 77 {
		t.Errorf("after raising: watchlist=%v progress=%v pos=%v, want pg13 back at 77s", wl, pr, pos)
	}
}

// ── FR-216 otp_required ─────────────────────────────────────────────────────────────────

func TestFR216_OwnerPinResetOnTwoFactorAccountWithoutOTPIsOtpRequiredNotPasswordIncorrect(t *testing.T) {
	// given: an owner with PIN 0420 on a 2FA DSM account
	e := newQAEnv(t)
	owner := e.setOwnerPin(qaAlice, "0420")
	var otpSeen string
	e.s.dsmAuthOverride = func(_ context.Context, user, pw, otp, _ string) (*dsmUserInfo, error) {
		otpSeen = otp
		if otp == "" {
			return nil, &dsmTwoFactorError{}
		}
		return &dsmUserInfo{Username: "alice", DisplayName: "Alice"}, nil
	}
	// when: reset without an OTP -> 403 otp_required (and not 401), PIN unchanged
	r := e.do(qaAlice, "POST", "/profiles/owner/pin/reset", jb(map[string]any{"password": "pw", "newPin": "5555"}), "")
	wantErr(t, r, 403, "otp_required")
	wantOK(t, e.verify(qaAlice, owner, "0420"), 200)
	// when: the same request carries the OTP -> it reaches DSM and the reset succeeds
	wantOK(t, e.do(qaAlice, "POST", "/profiles/owner/pin/reset", jb(map[string]any{"password": "pw", "newPin": "5555", "otp": "123456"}), ""), 200)
	if otpSeen != "123456" {
		t.Errorf("DSM was given otp %q, want 123456", otpSeen)
	}
	wantOK(t, e.verify(qaAlice, owner, "5555"), 200)
}

// ── FR-204 owner display name ───────────────────────────────────────────────────────────

func (e *qaEnv) loginAs(display string) {
	e.t.Helper()
	e.s.dsmAuthOverride = func(context.Context, string, string, string, string) (*dsmUserInfo, error) {
		return &dsmUserInfo{Username: "alice", DisplayName: display, SID: "s"}, nil
	}
	wantOK(e.t, e.do(qaAlice, "POST", "/auth/login", jb(map[string]any{"username": "alice", "password": "pw"}), ""), 200)
}

func ownerName(e *qaEnv) string {
	for _, p := range e.profiles(qaAlice) {
		if p["isOwner"] == true {
			return p["name"].(string)
		}
	}
	return ""
}

func TestFR204_SignInReplacesTheFallbackOwnerNameWithTheDSMDisplayName(t *testing.T) {
	// given: an owner still carrying the account-id fallback name "alice"
	e := newQAEnv(t)
	if got := ownerName(e); got != "alice" {
		t.Fatalf("precondition: fallback owner name = %q, want alice", got)
	}
	// when: sign-in reports display name "Alice Smith" / then: the owner is renamed
	e.loginAs("Alice Smith")
	if got := ownerName(e); got != "Alice Smith" {
		t.Errorf("owner name after sign-in = %q, want Alice Smith", got)
	}
}

func TestFR204_SignInNeverOverwritesANameTheOwnerChose(t *testing.T) {
	// given: the owner renamed the profile "Dad"
	e := newQAEnv(t)
	owner := e.setOwnerPin(qaAlice, "0420")
	wantOK(t, e.do(qaAlice, "PATCH", "/profiles/"+owner, jb(map[string]any{"ownerPin": "0420", "name": "Dad"}), ""), 200)
	// when: sign-in reports a different display name / then: "Dad" stays
	e.loginAs("Alice Smith")
	if got := ownerName(e); got != "Dad" {
		t.Errorf("owner name after sign-in = %q, want the chosen name Dad", got)
	}
}

func TestFR204_MigrationNamesTheOwnerFromTheStoredWebAPIUsernameElseTheAccountId(t *testing.T) {
	// given: an old-schema DB (accounts u_alice, u_bob, ...) where only alice has a recorded
	// WebAPI sign-in, with a case-preserved username
	db, path := oldSchemaDB(t)
	if _, err := db.Exec(`INSERT INTO webapi_sessions(sid,user_id,username,token,device_id,created_at) VALUES('s1','u_alice','AliceWeb','t','d',100)`); err != nil {
		t.Fatal(err)
	}
	// when
	if err := migrateProfiles(db, path); err != nil {
		t.Fatal(err)
	}
	// then: read back through a fresh handle
	want := map[string]string{"u_alice": "AliceWeb", "u_bob": "bob"}
	for u, name := range want {
		var got string
		if err := db.QueryRow(`SELECT name FROM profiles WHERE user_id=? AND is_owner=1`, u).Scan(&got); err != nil || got != name {
			t.Errorf("%s owner name = %q (err %v), want %q", u, got, err, name)
		}
	}
}

// ── FR-250 route census ─────────────────────────────────────────────────────────────────

// Dispositions follow docs/api/ProfilesAPI.md "Enforcement by route": F filtered, R refused,
// U unrestricted-only, P per-profile data, A account-scoped, X exempt (public/capability).
var routeDisposition = map[string]string{
	"POST /auth/quickconnect/resolve": "A", "POST /auth/login": "A", "POST /auth/logout": "A",
	"POST /auth/pairing/exchange": "A", "POST /auth/pairing/generate": "A", "POST /auth/refresh": "A",
	"GET /version": "A", "GET /libraries": "A", "GET /settings": "A", "PUT /settings": "A",
	"GET /sync/heartbeat": "A", "GET /sync/status": "A", "GET /sync/items": "A", "GET /sync/deleted": "A",
	"POST /playlists": "A", "DELETE /playlists/{id}": "A", "DELETE /playlists/{id}/items/{itemId}": "A",
	"DELETE /downloads/{itemId}": "A",

	"GET /playback/{sessionId}/stream": "X", "POST /playback/{sessionId}/stop": "X",
	"GET /playback/{sessionId}/master.m3u8": "X", "GET /playback/{sessionId}/init.mp4": "X",
	"GET /playback/{sessionId}/{name}.m4s": "X", "GET /playback/{sessionId}/{name}.ts": "X",
	"GET /playback/{sessionId}/{variant}.m3u8": "X", "GET /playback/{sessionId}/segments/{name}": "X",
	"GET /images/{id}": "X", "GET /tmdb/image": "X",

	"GET /genres": "F", "GET /suggested": "F", "GET /collections": "F", "GET /collections/{id}/items": "F",
	"GET /just-added": "F", "GET /libraries/summary": "F", "GET /items": "F", "GET /progress/all": "F",
	"GET /progress": "F", "GET /shows": "F", "GET /tv/shows": "F", "GET /playlists": "F",
	"GET /playlists/{id}": "F", "GET /downloads": "F", "GET /watchlist": "F", "GET /search": "F",

	"GET /items/{id}": "R", "GET /items/{id}/playback": "R",
	"GET /trickplay/{itemId}/trickplay.vtt": "R", "GET /trickplay/{itemId}/trickplay.jpg": "R",
	"GET /shows/{showName}": "R", "GET /tv/shows/{showId}/seasons": "R", "GET /tv/shows/{showId}/episodes": "R",
	"POST /playlists/{id}/items": "R", "POST /downloads/{itemId}": "R", "POST /watchlist/{itemId}": "R",

	"POST /items/{id}/progress": "P", "GET /watchlist/{itemId}": "P", "DELETE /watchlist/{itemId}": "P",

	"GET /items/{id}/tmdb-search": "U", "POST /items/{id}/tmdb-fix": "U",
	"GET /tv/shows/{showId}/tmdb-search": "U", "POST /tv/shows/{showId}/tmdb-fix": "U",
	"GET /admin/status": "U", "GET /admin/normalize/status": "U", "POST /admin/scan": "U",
	"POST /admin/metadata/refresh": "U",
}

// topLevelDisposition covers the routes main() mounts directly (WebAPI compatibility layer,
// web player). They cannot be walked without running main(), so main.go is scanned.
var topLevelDisposition = map[string]string{
	"/": "A", "/web": "A", "/web/*": "A", "/dsvideo": "A", "/dsvideo/": "A",
	"/webapi/query.cgi": "F/R", "/webapi/entry.cgi": "F/R", "/webapi/VideoStation/poster.cgi": "X",
	"/webapi/VideoStation/vtestreaming.cgi/*": "R", "/webapi/VideoStation/vtestreaming.cgi": "R",
	"/webapi/DSVideoServer/entry.cgi": "F/R", "/webapi/DSVideoServer/poster.cgi": "X",
	"/webapi/DSVideoServer/vtestreaming.cgi/*": "R", "/webapi/DSVideoServer/vtestreaming.cgi": "R",
}

func TestFR250_EveryRegisteredAPIRouteHasADisposition(t *testing.T) {
	// given: the real route table
	e := newQAEnv(t)
	r := chi.NewRouter()
	registerAPIRoutes(r, e.s)
	registered := map[string]bool{}
	if err := chi.Walk(r, func(method, route string, _ http.Handler, _ ...func(http.Handler) http.Handler) error {
		registered[method+" "+route] = true
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	// then: every route is classified (a new route fails here until someone decides its
	// FR-250 disposition and proves it), and no classification is stale
	var unclassified, stale []string
	for k := range registered {
		if _, ok := routeDisposition[k]; !ok && !strings.Contains(k, " /profiles") {
			unclassified = append(unclassified, k)
		}
	}
	for k := range routeDisposition {
		if !registered[k] {
			stale = append(stale, k)
		}
	}
	sort.Strings(unclassified)
	sort.Strings(stale)
	if len(unclassified) > 0 {
		t.Errorf("routes with NO FR-250 disposition (add to routeDisposition and to the enforcement matrices): %v", unclassified)
	}
	if len(stale) > 0 {
		t.Errorf("routeDisposition names routes that are not registered: %v", stale)
	}
	if len(registered) < 50 {
		t.Errorf("walk found only %d routes; the census is not seeing the router", len(registered))
	}
}

func TestFR250_EveryRouteMainMountsDirectlyHasADisposition(t *testing.T) {
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	s := string(src)
	start := strings.Index(s, "r := chi.NewRouter()")
	if start < 0 {
		t.Fatal("main() router construction not found")
	}
	end := start + strings.Index(s[start:], "\n}\n")
	re := regexp.MustCompile(`(?m)^\s*r\.(?:Get|Post|Put|Delete|Handle)\("(/[^"]*)"`)
	found := map[string]bool{}
	for _, m := range re.FindAllStringSubmatch(s[start:end], -1) {
		found[m[1]] = true
	}
	if len(found) < 10 {
		t.Fatalf("scan found only %d top-level routes: %v", len(found), found)
	}
	for p := range found {
		if _, ok := topLevelDisposition[p]; !ok {
			t.Errorf("top-level route %s has no FR-250 disposition (add to topLevelDisposition)", p)
		}
	}
	for p := range topLevelDisposition {
		if !found[p] {
			t.Errorf("topLevelDisposition names %s, which main() no longer mounts", p)
		}
	}
}
