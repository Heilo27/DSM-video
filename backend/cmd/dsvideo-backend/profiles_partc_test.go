package main

// TASK-916 part C: FRD-002 enforcement on the Synology WebAPI layer (FR-251) and the
// /suggested and /just-added rails (FR-250, FR-230). Every test observes the HTTP answer a
// client gets, not the SQL the handler builds.

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sort"
	"testing"
	"time"
)

// pcTitle inserts one library row. cert nil = unrated (NULL).
func (e *qaEnv) pcTitle(id, lib, typ, path, showName, genres, addedAt string, cert *string) {
	e.t.Helper()
	var show any
	if showName != "" {
		show = showName
	}
	_, err := e.db.Exec(`INSERT INTO items(id, library_id, type, title, path, show_name, added_at, updated_at, genres, content_rating)
		VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, lib, typ, id, path, show, addedAt, addedAt, genres, cert)
	if err != nil {
		e.t.Fatalf("seed %s: %v", id, err)
	}
}

// pcMovie is a lib_movies title at a cert, added at the given minute offset (higher = newer).
func (e *qaEnv) pcMovie(id string, cert *string, minute int) {
	e.pcTitle(id, "lib_movies", "movie", "/movies/"+id+".mkv", "", "Animation",
		time.Date(2026, 1, 1, 0, minute, 0, 0, time.UTC).Format(time.RFC3339), cert)
}

// pcFamily gives alice a level-2 ("Older Kids": G, PG, TV-Y…TV-PG) profile and returns its id.
func (e *qaEnv) pcFamily() (ownerID, kidID string) {
	e.t.Helper()
	pin := "1234"
	ownerID = e.setOwnerPin(qaAlice, pin)
	kidID = e.mustCreate(qaAlice, pin, "Kid", 2, nil)
	return
}

// pcSession registers a WebAPI session for u and returns its sid.
func pcSession(t *testing.T, u qaUser) string {
	t.Helper()
	sid := fmt.Sprintf("pc-sid-%s-%d", u.id, time.Now().UnixNano())
	webAPISessions.mu.Lock()
	webAPISessions.sessions[sid] = &WebAPISession{SID: sid, UserID: u.id, Username: u.name, Token: "x", DeviceID: "did_pc", CreatedAt: time.Now()}
	webAPISessions.mu.Unlock()
	t.Cleanup(func() {
		webAPISessions.mu.Lock()
		delete(webAPISessions.sessions, sid)
		webAPISessions.mu.Unlock()
	})
	return sid
}

type webAPIResp struct {
	Success bool                       `json:"success"`
	Data    map[string]json.RawMessage `json:"data"`
	Error   struct {
		Code int `json:"code"`
	} `json:"error"`
	hdr http.Header
}

func pcCall(t *testing.T, h func(http.ResponseWriter, *http.Request, string), method string, q url.Values) webAPIResp {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/webapi/entry.cgi?"+q.Encode(), nil)
	rec := httptest.NewRecorder()
	h(rec, req, method)
	var out webAPIResp
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("%s: undecodable WebAPI answer %q: %v", method, rec.Body.String(), err)
	}
	out.hdr = rec.Header()
	return out
}

// listTitles decodes data[key] as a list of {title} and data.total.
func (r webAPIResp) listTitles(t *testing.T, key string) (titles []string, total int) {
	t.Helper()
	if !r.Success {
		t.Fatalf("WebAPI list failed: code %d", r.Error.Code)
	}
	var rows []struct {
		Title string `json:"title"`
	}
	_ = json.Unmarshal(r.Data[key], &rows)
	_ = json.Unmarshal(r.Data["total"], &total)
	for _, row := range rows {
		titles = append(titles, row.Title)
	}
	sort.Strings(titles)
	return titles, total
}

func sameStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func pcMap(sid string, set func(m *idMapping)) {
	m := getOrCreateMapping(sid)
	m.mu.Lock()
	set(m)
	m.mu.Unlock()
}

// The five-level library every ceiling test uses: G, PG, PG-13, R, unrated.
func (e *qaEnv) pcLadderMovies() {
	e.pcMovie("m_g", sp("G"), 1)
	e.pcMovie("m_pg", sp("PG"), 2)
	e.pcMovie("m_pg13", sp("PG-13"), 3)
	e.pcMovie("m_r", sp("R"), 4)
	e.pcMovie("m_unrated", nil, 5)
}

// ── WebAPI (FR-251, AC-002-28) ──────────────────────────────────────────────────────────

func TestFR251_WebAPIMovieListHoldsToTheMostRestrictedProfile(t *testing.T) {
	e := newQAEnv(t)
	_, kid := e.pcFamily()
	e.pcLadderMovies()
	sid := pcSession(t, qaAlice)

	r := pcCall(t, e.s.handleWebAPIMovie, "list", url.Values{"_sid": {sid}})
	titles, total := r.listTitles(t, "movie")
	if want := []string{"m_g", "m_pg"}; !sameStrings(titles, want) {
		t.Errorf("WebAPI movie list for a family account = %v, want %v (no header → level-2 profile, FR-221)", titles, want)
	}
	if total != 2 {
		t.Errorf("total = %d, want 2: totals must count only the visible set (FR-250)", total)
	}
	if got := r.hdr.Get(profileHeader); got != kid {
		t.Errorf("X-DSVideo-Profile = %q, want the kid profile %q (FR-222)", got, kid)
	}

	// Paging is filtered before LIMIT: one row per page, two pages, then nothing.
	var paged []string
	for off := 0; off < 3; off++ {
		pt, _ := pcCall(t, e.s.handleWebAPIMovie, "list", url.Values{"_sid": {sid}, "limit": {"1"}, "offset": {fmt.Sprint(off)}, "sort_by": {"title"}}).listTitles(t, "movie")
		paged = append(paged, pt...)
	}
	if want := []string{"m_g", "m_pg"}; !sameStrings(paged, want) {
		t.Errorf("paged WebAPI movie list = %v, want %v", paged, want)
	}
}

func TestFR251_WebAPIMovieListShowsEverythingWithoutRestrictedProfiles(t *testing.T) {
	e := newQAEnv(t)
	owner := e.ownerID(qaAlice)
	e.pcLadderMovies()
	sid := pcSession(t, qaAlice)

	r := pcCall(t, e.s.handleWebAPIMovie, "list", url.Values{"_sid": {sid}})
	titles, total := r.listTitles(t, "movie")
	if len(titles) != 5 || total != 5 {
		t.Errorf("owner-only account sees %v (total %d), want all five incl. unrated (AC-002-14)", titles, total)
	}
	if got := r.hdr.Get(profileHeader); got != owner {
		t.Errorf("X-DSVideo-Profile = %q, want owner %q", got, owner)
	}
}

func TestFR251_WebAPIMovieDetailAndStreamRefuseTitlesAboveTheCeiling(t *testing.T) {
	e := newQAEnv(t)
	e.pcFamily()
	e.pcLadderMovies()
	sid := pcSession(t, qaAlice)
	// Stale mappings, e.g. taken before the kid profile existed.
	pcMap(sid, func(m *idMapping) {
		m.movieIDs["11"] = "m_g"
		m.movieIDs["12"] = "m_r"
		m.movieIDs["13"] = "m_unrated"
	})

	if r := pcCall(t, e.s.handleWebAPIMovie, "getinfo", url.Values{"_sid": {sid}, "id": {"11"}}); !r.Success {
		t.Errorf("getinfo on a G title failed for the kid profile: code %d", r.Error.Code)
	}
	for _, id := range []string{"12", "13"} {
		r := pcCall(t, e.s.handleWebAPIMovie, "getinfo", url.Values{"_sid": {sid}, "id": {id}})
		if r.Success || r.Error.Code != webAPIErrNoPermission {
			t.Errorf("getinfo mapper %s (above the ceiling): success=%v code=%d, want code %d", id, r.Success, r.Error.Code, webAPIErrNoPermission)
		}
		s := pcCall(t, e.s.handleWebAPIStreaming, "open", url.Values{"_sid": {sid}, "id": {id}})
		if s.Success || s.Error.Code != webAPIErrNoPermission {
			t.Errorf("Streaming.open mapper %s (above the ceiling): success=%v code=%d, want code %d", id, s.Success, s.Error.Code, webAPIErrNoPermission)
		}
	}
	// Both stream-open routes share webAPIStreamingOpen; check the vtestreaming.cgi POST too.
	req := httptest.NewRequest(http.MethodPost, "/webapi/VideoStation/vtestreaming.cgi?"+url.Values{"_sid": {sid}, "id": {"12"}, "method": {"open"}}.Encode(), nil)
	rec := httptest.NewRecorder()
	e.s.handleWebAPIVTEStreamingOpen(rec, req)
	var v webAPIResp
	_ = json.Unmarshal(rec.Body.Bytes(), &v)
	if v.Success || v.Error.Code != webAPIErrNoPermission {
		t.Errorf("vtestreaming open on an R title: %s, want error %d", rec.Body.String(), webAPIErrNoPermission)
	}
	e.s.mu.RLock()
	n := len(e.s.playSessions)
	e.s.mu.RUnlock()
	if n != 0 {
		t.Errorf("%d play sessions created for titles above the ceiling, want 0", n)
	}
}

func TestFR251_WebAPITVShowsAndEpisodesHoldToTheCeiling(t *testing.T) {
	e := newQAEnv(t)
	e.pcFamily()
	e.s.cfg.TVPath = "/tv"
	at := "2026-01-01T00:00:00Z"
	for i := 1; i <= 2; i++ {
		e.pcTitle(fmt.Sprintf("k%d", i), "lib_tv", "episode", fmt.Sprintf("/tv/KidShow/e%d.mkv", i), "KidShow", "Animation", at, sp("TV-Y"))
		e.pcTitle(fmt.Sprintf("a%d", i), "lib_tv", "episode", fmt.Sprintf("/tv/AdultShow/e%d.mkv", i), "AdultShow", "Drama", at, sp("TV-MA"))
		e.pcTitle(fmt.Sprintf("u%d", i), "lib_tv", "episode", fmt.Sprintf("/tv/HomeVideos/e%d.mkv", i), "HomeVideos", "", at, nil)
	}
	sid := pcSession(t, qaAlice)

	shows, total := pcCall(t, e.s.handleWebAPITVShow, "list", url.Values{"_sid": {sid}}).listTitles(t, "tvshow")
	if !sameStrings(shows, []string{"KidShow"}) || total != 1 {
		t.Errorf("WebAPI TV show list = %v (total %d), want [KidShow] (total 1)", shows, total)
	}
	eps, total := pcCall(t, e.s.handleWebAPITVShowEpisode, "list", url.Values{"_sid": {sid}}).listTitles(t, "tvshow_episode")
	if !sameStrings(eps, []string{"k1", "k2"}) || total != 2 {
		t.Errorf("WebAPI episode list = %v (total %d), want [k1 k2] (total 2)", eps, total)
	}

	pcMap(sid, func(m *idMapping) {
		m.tvShows["21"] = "AdultShow"
		m.tvShows["22"] = "KidShow"
		m.tvIDs["31"] = "a1"
		m.tvIDs["32"] = "u1"
	})
	// Episodes of a hidden show, listed by tvshow_id, come back empty.
	eps, total = pcCall(t, e.s.handleWebAPITVShowEpisode, "list", url.Values{"_sid": {sid}, "tvshow_id": {"21"}}).listTitles(t, "tvshow_episode")
	if len(eps) != 0 || total != 0 {
		t.Errorf("episodes of AdultShow for the kid profile = %v (total %d), want none", eps, total)
	}
	if r := pcCall(t, e.s.handleWebAPITVShow, "getinfo", url.Values{"_sid": {sid}, "id": {"21"}}); r.Success || r.Error.Code != webAPIErrNoPermission {
		t.Errorf("TVShow getinfo on AdultShow: success=%v code=%d, want %d", r.Success, r.Error.Code, webAPIErrNoPermission)
	}
	if r := pcCall(t, e.s.handleWebAPITVShow, "getinfo", url.Values{"_sid": {sid}, "id": {"22"}}); !r.Success {
		t.Errorf("TVShow getinfo on KidShow failed: code %d", r.Error.Code)
	}
	for _, id := range []string{"31", "32"} {
		if r := pcCall(t, e.s.handleWebAPITVShowEpisode, "getinfo", url.Values{"_sid": {sid}, "id": {id}}); r.Success || r.Error.Code != webAPIErrNoPermission {
			t.Errorf("episode getinfo mapper %s: success=%v code=%d, want %d", id, r.Success, r.Error.Code, webAPIErrNoPermission)
		}
	}
}

func TestFR231_WebAPIWatchStatusGoesToTheRestrictedDefaultAndIsAcceptedAboveTheCeiling(t *testing.T) {
	e := newQAEnv(t)
	owner, kid := e.pcFamily()
	e.pcLadderMovies()
	sid := pcSession(t, qaAlice)
	pcMap(sid, func(m *idMapping) { m.movieIDs["12"] = "m_r" })

	r := pcCall(t, e.s.handleWebAPIWatchStatus, "update", url.Values{"_sid": {sid}, "id": {"12"}, "time": {"77"}, "total_time": {"5000"}})
	if !r.Success {
		t.Fatalf("WatchStatus update failed: code %d", r.Error.Code)
	}
	if n := e.count(`SELECT COUNT(*) FROM progress WHERE item_id='m_r' AND profile_id=? AND position_seconds=77`, kid); n != 1 {
		t.Errorf("position not stored on the kid profile (FR-221 default), rows=%d", n)
	}
	if n := e.count(`SELECT COUNT(*) FROM progress WHERE profile_id=?`, owner); n != 0 {
		t.Errorf("owner profile received %d progress rows from a header-less WebAPI write", n)
	}
	// The WebAPI list shows that same profile's progress, not another's.
	_, _ = e.s.db.Exec(`INSERT INTO progress(item_id, user_id, profile_id, position_seconds, duration_seconds, updated_at, write_seq)
		VALUES('m_g', ?, ?, 999, 5000, '2026-01-01T00:00:00Z', 1)`, qaAlice.id, owner)
	r = pcCall(t, e.s.handleWebAPIMovie, "list", url.Values{"_sid": {sid}})
	var rows []map[string]any
	_ = json.Unmarshal(r.Data["movie"], &rows)
	for _, m := range rows {
		if m["title"] == "m_g" && m["watch_status"] != nil {
			t.Errorf("kid's WebAPI list shows the owner's position on m_g: %v", m["watch_status"])
		}
	}
}

// ── Rails (FR-250, FR-230) ──────────────────────────────────────────────────────────────

type railItem struct {
	ID            string  `json:"id"`
	AgeLevel      *int    `json:"ageLevel"`
	ContentRating *string `json:"contentRating"`
}

func railItems(t *testing.T, r qaResp) []railItem {
	t.Helper()
	if r.code != 200 {
		t.Fatalf("rail answered %d: %s", r.code, r.raw)
	}
	var body struct {
		Genre string     `json:"genre"`
		Items []railItem `json:"items"`
	}
	if err := json.Unmarshal(r.raw, &body); err != nil {
		t.Fatalf("decode rail: %v", err)
	}
	return body.Items
}

func TestFR250_JustAddedIsFullForARestrictedProfileWhenTheNewestTitlesAreAdult(t *testing.T) {
	e := newQAEnv(t)
	owner, kid := e.pcFamily()
	// 30 adult or unrated titles are the newest; 6 G titles are older. A rail cut to 24 and
	// then trimmed for the kid would be empty.
	for i := 0; i < 30; i++ {
		cert := sp("R")
		if i%2 == 0 {
			cert = nil
		}
		e.pcMovie(fmt.Sprintf("adult%02d", i), cert, 30+i)
	}
	for i := 0; i < 6; i++ {
		e.pcMovie(fmt.Sprintf("kids%02d", i), sp("G"), i)
	}

	kidItems := railItems(t, e.do(qaAlice, "GET", "/just-added?limit=16", "", kid))
	if len(kidItems) != 6 {
		t.Errorf("kid's Just Added has %d titles, want all 6 visible ones", len(kidItems))
	}
	for _, it := range kidItems {
		if it.AgeLevel == nil || *it.AgeLevel > 2 {
			t.Errorf("kid's Just Added carries %s at ageLevel %v (ceiling 2)", it.ID, it.AgeLevel)
		}
	}
	// No header serves the same restricted rail (FR-221).
	if n := len(railItems(t, e.do(qaAlice, "GET", "/just-added?limit=16", "", ""))); n != 6 {
		t.Errorf("header-less Just Added has %d titles, want the kid's 6", n)
	}
	// The owner still sees the adult and unrated titles, unrated as null / 4 (FR-242).
	ownerItems := railItems(t, e.do(qaAlice, "GET", "/just-added?limit=16", "", owner))
	if len(ownerItems) != 16 {
		t.Fatalf("owner's Just Added has %d titles, want 16", len(ownerItems))
	}
	sawUnrated := false
	for _, it := range ownerItems {
		if it.ContentRating == nil {
			sawUnrated = true
			if it.AgeLevel == nil || *it.AgeLevel != 4 {
				t.Errorf("unrated %s sent with ageLevel %v, want 4", it.ID, it.AgeLevel)
			}
		}
	}
	if !sawUnrated {
		t.Error("owner's Just Added has no unrated title; Adult profiles must see unrated (AC-002-14)")
	}
}

func TestFR250_SuggestedHoldsToTheCeilingAndIsNotLeftShort(t *testing.T) {
	e := newQAEnv(t)
	owner, kid := e.pcFamily()
	e.pcMovie("seed_g", sp("G"), 0)
	for i := 0; i < 20; i++ {
		cert := sp("PG-13")
		if i%2 == 0 {
			cert = nil
		}
		e.pcMovie(fmt.Sprintf("adult%02d", i), cert, 10+i)
	}
	for i := 0; i < 4; i++ {
		e.pcMovie(fmt.Sprintf("kids%02d", i), sp("PG"), 40+i)
	}
	// Horror, R: the kid's most recent progress (accepted above the ceiling, FR-231). It must
	// not seed the rail; the visible G title must.
	e.pcTitle("horror_r", "lib_movies", "movie", "/movies/horror_r.mkv", "", "Horror", "2026-01-01T00:00:00Z", sp("R"))
	ins := `INSERT INTO progress(item_id, user_id, profile_id, position_seconds, duration_seconds, updated_at, write_seq) VALUES(?,?,?,?,?,?,?)`
	if _, err := e.db.Exec(ins, "seed_g", qaAlice.id, kid, 60, 5000, "2026-02-01T00:00:00Z", 1); err != nil {
		t.Fatal(err)
	}
	if _, err := e.db.Exec(ins, "horror_r", qaAlice.id, kid, 60, 5000, "2026-02-02T00:00:00Z", 2); err != nil {
		t.Fatal(err)
	}

	for run := 0; run < 5; run++ { // RANDOM() ordering: a post-LIMIT filter would fail some run
		r := e.do(qaAlice, "GET", "/suggested?limit=4", "", kid)
		items := railItems(t, r)
		if g := r.str("genre"); g != "Animation" {
			t.Fatalf("kid's Suggested seeded from %q, want Animation (the R Horror title is above the ceiling)", g)
		}
		if len(items) != 4 {
			t.Errorf("kid's Suggested has %d titles, want 4: the ceiling must be in the query, not applied after LIMIT", len(items))
		}
		for _, it := range items {
			if it.AgeLevel == nil || *it.AgeLevel > 2 || it.ID == "seed_g" {
				t.Errorf("kid's Suggested includes %s (ageLevel %v)", it.ID, it.AgeLevel)
			}
		}
	}

	// The owner has no history: their rail is empty, not the kid's (FR-230).
	if items := railItems(t, e.do(qaAlice, "GET", "/suggested?limit=4", "", owner)); len(items) != 0 {
		t.Errorf("owner's Suggested has %d titles built from the kid's history", len(items))
	}
}
