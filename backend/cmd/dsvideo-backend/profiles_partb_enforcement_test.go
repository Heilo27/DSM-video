package main

// TASK-916 part B: FR-250 route dispositions (docs/api/ProfilesAPI.md "Enforcement by route").
// Every test drives the REAL router (registerAPIRoutes) with a signed JWT and observes the
// HTTP answer a client reads. Fixtures use unique tokens ("FxR…") so a leak anywhere in a
// response body is a substring match, and every "must not appear" check is paired with a
// "must appear" check on a title the viewer may see (a blank response proves nothing).
//
// Viewers (one account, "alice"):
//   kid     - "Little Kids", level 1   (header names it)
//   anon    - no header, so FR-221 resolves to the most restricted profile, which is kid
//   adult   - the owner, level 4       (header names it); sees unrated (FR-242)

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	enfPin = "4821"

	// Movies: G, R, unrated. Folder, id, genre are all distinct tokens.
	enfMovG  = "FxMovG"
	enfMovR  = "FxMovR"
	enfMovUn = "FxMovUn"
	// Shows (folder names are the show ids): G, R, unrated; episode ids follow.
	enfShowG  = "FxShowG"
	enfShowR  = "FxShowR"
	enfShowUn = "FxShowUn"
)

var (
	enfGenre = map[string]string{enfMovG: "FxGenreFamily", enfMovR: "FxGenreHorror", enfMovUn: "FxGenreMystery"}
	// Episode ids per show, two for each so counts are not 0/1.
	enfEps = map[string][]string{
		enfShowG:  {"FxEpG1", "FxEpG2"},
		enfShowR:  {"FxEpR1", "FxEpR2"},
		enfShowUn: {"FxEpUn1"},
	}
)

type enfWorld struct {
	*qaEnv
	root       string
	ownerID    string
	kidID      string
	kidHdr     string
	adultHdr   string
	playlistID string
}

// enfViewerSpec is one of the three viewers of the matrix.
type enfViewerSpec struct {
	name       string
	header     func(w *enfWorld) string
	restricted bool
}

var enfViewers = []enfViewerSpec{
	{"kid", func(w *enfWorld) string { return w.kidID }, true},
	{"anon_no_header", func(w *enfWorld) string { return "" }, true},
	{"adult", func(w *enfWorld) string { return w.ownerID }, false},
}

// newEnfWorld builds the library, the family account and every per-viewer row the filtered
// listings need (progress on every title under every profile, downloads, playlist).
func newEnfWorld(t *testing.T) *enfWorld {
	t.Helper()
	e := newQAEnv(t)
	root := t.TempDir()
	movies, tv := filepath.Join(root, "movies"), filepath.Join(root, "tv")
	e.s.cfg.MoviesPath, e.s.cfg.TVPath = movies, tv
	e.s.playSessions = map[string]PlaySession{} // main() builds this; the bare test Server does not
	w := &enfWorld{qaEnv: e, root: root}

	cert := map[string]*string{enfMovG: sp("G"), enfMovR: sp("R"), enfMovUn: nil}
	for _, id := range []string{enfMovG, enfMovR, enfMovUn} {
		dir := filepath.Join(movies, id+"Folder")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		p := filepath.Join(dir, id+".mp4")
		if err := os.WriteFile(p, []byte("BYTES-OF-"+id), 0o644); err != nil {
			t.Fatal(err)
		}
		_, err := e.db.Exec(`INSERT INTO items(id, library_id, type, title, path, added_at, updated_at, genres, content_rating,
			video_codec, audio_codec, container, needs_transcode, duration_seconds)
			VALUES(?, 'lib_movies', 'movie', ?, ?, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', ?, ?, 'h264', 'aac', 'mp4', 0, 5400)`,
			id, id, p, enfGenre[id], cert[id])
		if err != nil {
			t.Fatalf("seed %s: %v", id, err)
		}
	}
	showCert := map[string]*string{enfShowG: sp("TV-G"), enfShowR: sp("TV-MA"), enfShowUn: nil}
	for show, eps := range enfEps {
		for i, id := range eps {
			p := filepath.Join(tv, show, fmt.Sprintf("S01E%02d.mkv", i+1))
			_, err := e.db.Exec(`INSERT INTO items(id, library_id, type, title, path, show_name, season_number, episode_number, added_at, updated_at, content_rating, duration_seconds)
				VALUES(?, 'lib_tv', 'episode', ?, ?, ?, 1, ?, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', ?, 1800)`,
				id, id, p, show, i+1, showCert[show])
			if err != nil {
				t.Fatalf("seed %s: %v", id, err)
			}
		}
	}

	w.ownerID = e.setOwnerPin(qaAlice, enfPin)
	w.kidID = e.mustCreate(qaAlice, enfPin, "Little Kids", 1, nil)
	w.kidHdr, w.adultHdr = w.kidID, w.ownerID

	// Progress on every title under BOTH profiles (a restricted profile's progress write is
	// accepted at any level, FR-231), so the filtered progress reads have rows to hide.
	allIDs := []string{enfMovG, enfMovR, enfMovUn}
	for _, eps := range enfEps {
		allIDs = append(allIDs, eps...)
	}
	for _, hdr := range []string{w.kidID, w.ownerID} {
		for _, id := range allIDs {
			r := e.do(qaAlice, "POST", "/items/"+id+"/progress", `{"positionSeconds":60,"durationSeconds":1000}`, hdr)
			if r.code != http.StatusOK {
				t.Fatalf("seed progress %s as %s: %d %s", id, hdr, r.code, r.raw)
			}
		}
	}
	// Watchlist rows for the kid profile above its ceiling: the API refuses them (FR-231), so
	// they are rows a ceiling LOWERED after the fact leaves behind (FR-207). Written directly.
	for _, id := range []string{enfMovG, enfMovR, enfMovUn} {
		for _, p := range []string{w.kidID, w.ownerID} {
			if _, err := e.db.Exec(`INSERT INTO watchlist(item_id, user_id, profile_id) VALUES(?,?,?)`, id, qaAlice.id, p); err != nil {
				t.Fatalf("seed watchlist: %v", err)
			}
		}
	}
	// Downloads and one playlist are per account: written by the adult, who may mark anything.
	for _, id := range []string{enfMovG, enfMovR, enfMovUn} {
		r := e.do(qaAlice, "POST", "/downloads/"+id, "", w.ownerID)
		if r.code != http.StatusOK {
			t.Fatalf("seed download %s: %d %s", id, r.code, r.raw)
		}
	}
	r := e.do(qaAlice, "POST", "/playlists", `{"title":"Family night"}`, w.ownerID)
	if r.code != http.StatusOK && r.code != http.StatusCreated {
		t.Fatalf("seed playlist: %d %s", r.code, r.raw)
	}
	w.playlistID = r.str("id")
	if w.playlistID == "" {
		t.Fatalf("seed playlist: no id in %s", r.raw)
	}
	for _, id := range []string{enfMovG, enfMovR, enfMovUn} {
		r := e.do(qaAlice, "POST", "/playlists/"+w.playlistID+"/items", jb(map[string]any{"itemId": id}), w.ownerID)
		if r.code != http.StatusOK {
			t.Fatalf("seed playlist item %s: %d %s", id, r.code, r.raw)
		}
	}
	return w
}

func (w *enfWorld) get(v enfViewerSpec, path string) qaResp {
	w.t.Helper()
	return w.do(qaAlice, "GET", path, "", v.header(w))
}

// mentions reports whether the body names token.
func (r qaResp) mentions(token string) bool { return strings.Contains(string(r.raw), token) }

// ── 1. Filtered listings (F) ────────────────────────────────────────────────────────────

// enfListing is one F route. visible are tokens a restricted viewer MUST get; hidden are
// tokens only an unrestricted viewer gets (R and unrated titles, their folders and genres).
// adultAlso are extra tokens the adult must see (the hidden set is always among them).
type enfListing struct {
	name    string
	path    string
	visible []string
	hidden  []string
}

func enfListings(w *enfWorld) []enfListing {
	movieHidden := []string{enfMovR, enfMovUn}
	return []enfListing{
		// OC-F-items: GET /items, all titles of a library
		{"items_all", "/items?libraryId=lib_movies", []string{enfMovG}, movieHidden},
		{"items_all_tv", "/items?libraryId=lib_tv", []string{"FxEpG1", "FxEpG2"}, []string{"FxEpR1", "FxEpR2", "FxEpUn1"}},
		{"items_justAdded", "/items?libraryId=lib_movies&filter=justAdded", []string{enfMovG}, movieHidden},
		{"items_byFolder_movies", "/items?libraryId=lib_movies&filter=byFolder", []string{enfMovG + "Folder"}, []string{enfMovR + "Folder", enfMovUn + "Folder"}},
		{"items_byFolder_tv", "/items?libraryId=lib_tv&filter=byFolder", []string{enfShowG}, []string{enfShowR, enfShowUn}},
		{"items_justWatched", "/items?libraryId=lib_movies&filter=justWatched", []string{enfMovG}, movieHidden},
		{"items_by_genre_hidden_genre", "/items?libraryId=lib_movies&genre=" + enfGenre[enfMovR], nil, []string{enfMovR}},
		{"search", "/search?q=Fx", []string{enfMovG}, append(append([]string{}, movieHidden...), "FxEpR1", "FxEpUn1")},
		{"search_by_exact_hidden_title", "/search?q=" + enfMovR, nil, []string{enfMovR}},
		{"genres", "/genres?libraryId=lib_movies", []string{enfGenre[enfMovG]}, []string{enfGenre[enfMovR], enfGenre[enfMovUn]}},
		{"shows", "/shows", []string{enfShowG}, []string{enfShowR, enfShowUn}},
		{"tv_shows", "/tv/shows", []string{enfShowG}, []string{enfShowR, enfShowUn}},
		{"progress_all", "/progress/all", []string{enfMovG, "FxEpG1"}, []string{enfMovR, enfMovUn, "FxEpR1", "FxEpUn1"}},
		{"progress_batch", "/progress?ids=" + strings.Join([]string{enfMovG, enfMovR, enfMovUn, "FxEpR1", "FxEpUn1"}, ","), []string{enfMovG}, []string{enfMovR, enfMovUn, "FxEpR1", "FxEpUn1"}},
		{"watchlist", "/watchlist", []string{enfMovG}, movieHidden},
		{"downloads", "/downloads", []string{enfMovG}, movieHidden},
		{"playlists_list_counts", "/playlists", []string{"Family night"}, nil},
		{"playlist_detail", "/playlists/" + w.playlistID, []string{enfMovG}, movieHidden},
		{"just_added_rail", "/just-added", []string{enfMovG, "FxEpG1"}, []string{enfMovR, enfMovUn, "FxEpR1", "FxEpUn1"}},
	}
}

// TestFR250_FilteredListingsHoldToTheCeiling proves every F route in ProfilesAPI.md for the
// three viewers. Mutation: delete the andVisible/visibleItemFrag call of any one handler and
// that row's kid/anon subtests go red (see the mutation census in the QA verdict).
func TestFR250_FilteredListingsHoldToTheCeiling(t *testing.T) {
	// given: one library with G, R and unrated titles in movies and TV, and rows for each
	w := newEnfWorld(t)
	for _, l := range enfListings(w) {
		for _, v := range enfViewers {
			t.Run(l.name+"/"+v.name, func(t *testing.T) {
				// when: the viewer reads the listing
				r := w.get(v, l.path)
				// then: 200, naming the profile it used
				if r.code != http.StatusOK {
					t.Fatalf("GET %s as %s = %d %s", l.path, v.name, r.code, r.raw)
				}
				for _, tok := range l.visible {
					if !r.mentions(tok) {
						t.Errorf("GET %s as %s: %q must be listed, body %s", l.path, v.name, tok, r.raw)
					}
				}
				for _, tok := range l.hidden {
					if v.restricted && r.mentions(tok) {
						t.Errorf("GET %s as %s leaks %q above the ceiling: %s", l.path, v.name, tok, r.raw)
					}
					if !v.restricted && !r.mentions(tok) {
						t.Errorf("GET %s as the Adult profile must include %q (unrated and R are visible at level 4): %s", l.path, tok, r.raw)
					}
				}
			})
		}
	}
}

// ── 2. Counts and totals reflect only the visible set (AC-002-13) ───────────────────────

func TestFR250_TotalsAndCountsEqualTheVisibleCount(t *testing.T) {
	// given: 1 visible movie of 3, and 2 visible episodes of 5
	w := newEnfWorld(t)
	type want struct{ kid, adult int }
	cases := []struct {
		name, path, key string
		want            want
	}{
		{"items_movies_total", "/items?libraryId=lib_movies", "total", want{1, 3}},
		{"items_tv_total", "/items?libraryId=lib_tv", "total", want{2, 5}},
		{"search_total", "/search?q=" + enfMovG[:5], "total", want{1, 3}},
	}
	for _, c := range cases {
		for _, v := range enfViewers {
			t.Run(c.name+"/"+v.name, func(t *testing.T) {
				r := w.get(v, c.path)
				if r.code != http.StatusOK {
					t.Fatalf("%s: %d %s", c.path, r.code, r.raw)
				}
				exp := c.want.adult
				if v.restricted {
					exp = c.want.kid
				}
				if got := r.num(c.key); got != exp {
					t.Errorf("%s as %s: %s = %d, want %d (%s)", c.path, v.name, c.key, got, exp, r.raw)
				}
			})
		}
	}

	// libraries/summary: per-library counts are visible counts.
	for _, v := range enfViewers {
		t.Run("libraries_summary/"+v.name, func(t *testing.T) {
			r := w.get(v, "/libraries/summary")
			wantMovies, wantTV := 3, 5
			if v.restricted {
				wantMovies, wantTV = 1, 2
			}
			counts := map[string]int{}
			libs, _ := r.js["libraries"].([]any)
			for _, l := range libs {
				m := l.(map[string]any)
				counts[m["libraryId"].(string)] = int(m["count"].(float64))
			}
			if counts["lib_movies"] != wantMovies || counts["lib_tv"] != wantTV {
				t.Errorf("summary as %s = %v, want movies=%d tv=%d", v.name, counts, wantMovies, wantTV)
			}
		})
	}

	// byFolder counts are visible counts: the TV library has one folder per show.
	t.Run("byFolder_counts", func(t *testing.T) {
		kid := w.get(enfViewers[0], "/items?libraryId=lib_tv&filter=byFolder")
		adult := w.get(enfViewers[2], "/items?libraryId=lib_tv&filter=byFolder")
		folderCount := func(r qaResp, name string) int {
			fs, _ := r.js["folders"].([]any)
			for _, f := range fs {
				m := f.(map[string]any)
				if m["name"] == name {
					return int(m["count"].(float64))
				}
			}
			return -1
		}
		if got := folderCount(kid, enfShowG); got != 2 {
			t.Errorf("kid sees %d episodes in %s, want 2 (%s)", got, enfShowG, kid.raw)
		}
		if got := folderCount(kid, enfShowR); got != -1 {
			t.Errorf("kid is told about folder %s (%s)", enfShowR, kid.raw)
		}
		if got := folderCount(adult, enfShowR); got != 2 {
			t.Errorf("adult sees %d episodes in %s, want 2 (%s)", got, enfShowR, adult.raw)
		}
	})
}

// ── 3. Refused above the ceiling (R) ────────────────────────────────────────────────────

type enfRefusal struct {
	name   string
	method string
	// path/body are built for one target (a movie id, or a show id for show routes).
	path    func(target string) string
	body    func(w *enfWorld, target string) string
	targets [3]string // G, R, unrated
	okCode  int       // what an unrestricted viewer (and a G target for the kid) gets
}

func enfRefusals() []enfRefusal {
	movies := [3]string{enfMovG, enfMovR, enfMovUn}
	shows := [3]string{enfShowG, enfShowR, enfShowUn}
	noBody := func(*enfWorld, string) string { return "" }
	return []enfRefusal{
		{"item_detail", "GET", func(id string) string { return "/items/" + id }, noBody, movies, 200},
		{"item_playback", "GET", func(id string) string { return "/items/" + id + "/playback" }, noBody, movies, 200},
		{"trickplay_vtt", "GET", func(id string) string { return "/trickplay/" + id + "/trickplay.vtt" }, noBody, movies, 0},
		{"trickplay_sprite", "GET", func(id string) string { return "/trickplay/" + id + "/trickplay.jpg" }, noBody, movies, 0},
		{"show_detail_legacy", "GET", func(id string) string { return "/shows/" + id }, noBody, shows, 200},
		{"tv_show_seasons", "GET", func(id string) string { return "/tv/shows/" + id + "/seasons" }, noBody, shows, 200},
		{"tv_show_episodes", "GET", func(id string) string { return "/tv/shows/" + id + "/episodes" }, noBody, shows, 200},
		{"watchlist_add", "POST", func(id string) string { return "/watchlist/" + id }, noBody, movies, 200},
		{"playlist_add_item", "POST", func(string) string { return "" }, func(w *enfWorld, id string) string { return jb(map[string]any{"itemId": id}) }, movies, 200},
		{"download_add", "POST", func(id string) string { return "/downloads/" + id }, noBody, movies, 200},
	}
}

// TestFR250_RefusedRoutesAnswerContentRestricted: for each R route, a restricted viewer
// opening the R or the unrated title gets 403 content_restricted and the G title is not
// refused; the Adult profile is never refused.
func TestFR250_RefusedRoutesAnswerContentRestricted(t *testing.T) {
	// given: a library with G, R and unrated titles and three viewers
	w := newEnfWorld(t)
	for _, rf := range enfRefusals() {
		for _, v := range enfViewers {
			for i, label := range []string{"G", "R", "unrated"} {
				target := rf.targets[i]
				t.Run(rf.name+"/"+v.name+"/"+label, func(t *testing.T) {
					path := rf.path(target)
					if rf.name == "playlist_add_item" {
						path = "/playlists/" + w.playlistID + "/items"
					}
					// when
					r := w.do(qaAlice, rf.method, path, rf.body(w, target), v.header(w))
					// then
					mustRefuse := v.restricted && label != "G"
					if mustRefuse {
						wantErr(t, r, http.StatusForbidden, "content_restricted")
						return
					}
					if r.str("error") == "content_restricted" {
						t.Fatalf("%s %s as %s refused a title it may see: %d %s", rf.method, path, v.name, r.code, r.raw)
					}
					if rf.okCode != 0 && r.code != rf.okCode {
						t.Errorf("%s %s as %s = %d %s, want %d", rf.method, path, v.name, r.code, r.raw, rf.okCode)
					}
					// A trickplay route has no ffmpeg in the harness: an allowed viewer gets the
					// route's OWN answer, which is never 403.
					if rf.okCode == 0 && r.code == http.StatusForbidden {
						t.Errorf("%s %s as %s forbidden: %s", rf.method, path, v.name, r.raw)
					}
				})
			}
		}
	}
}

// ── 4. Unrestricted-only (U) ────────────────────────────────────────────────────────────

func TestFR250_UnrestrictedOnlyRoutesRefuseRestrictedProfiles(t *testing.T) {
	// given: the three viewers
	w := newEnfWorld(t)
	routes := []struct{ method, path, body string }{
		{"GET", "/items/" + enfMovG + "/tmdb-search?q=x", ""},
		{"POST", "/items/" + enfMovG + "/tmdb-fix", `{"tmdbId":1}`},
		{"GET", "/tv/shows/" + enfShowG + "/tmdb-search?q=x", ""},
		{"POST", "/tv/shows/" + enfShowG + "/tmdb-fix", `{"tmdbId":1}`},
		{"GET", "/admin/status", ""},
		{"GET", "/admin/normalize/status", ""},
		{"POST", "/admin/scan", ""},
		{"POST", "/admin/metadata/refresh", ""},
	}
	for _, rt := range routes {
		for _, v := range enfViewers {
			t.Run(rt.method+rt.path+"/"+v.name, func(t *testing.T) {
				r := w.do(qaAlice, rt.method, rt.path, rt.body, v.header(w))
				if v.restricted {
					wantErr(t, r, http.StatusForbidden, "profile_restricted")
					return
				}
				// The adult gets past THIS gate: the route's own answer (404 no tmdb, 403
				// admin_required, 200...) is anything but profile_restricted.
				if r.str("error") == "profile_restricted" {
					t.Errorf("%s %s refused the Adult profile as profile_restricted: %s", rt.method, rt.path, r.raw)
				}
			})
		}
	}
}

// ── 5. Account-scoped sync is NOT filtered (AC-002-29) ──────────────────────────────────

func TestAC00229_SyncItemsCarriesEveryItemWithAgeLevelForEveryViewer(t *testing.T) {
	// given: 8 items in the account (3 movies, 5 episodes), 5 of them above level 1
	w := newEnfWorld(t)
	wantLevels := map[string]int{
		enfMovG: 1, enfMovR: 4, enfMovUn: 4,
		"FxEpG1": 1, "FxEpG2": 1, "FxEpR1": 4, "FxEpR2": 4, "FxEpUn1": 4,
	}
	for _, v := range enfViewers {
		t.Run(v.name, func(t *testing.T) {
			r := w.get(v, "/sync/items?since=0&limit=500")
			if r.code != http.StatusOK {
				t.Fatalf("/sync/items = %d %s", r.code, r.raw)
			}
			items, _ := r.js["items"].([]any)
			got := map[string]int{}
			for _, it := range items {
				m := it.(map[string]any)
				lvl, ok := m["ageLevel"].(float64)
				if !ok {
					t.Errorf("item %v carries no ageLevel", m["id"])
				}
				got[m["id"].(string)] = int(lvl)
			}
			if len(got) != len(wantLevels) {
				t.Errorf("/sync/items as %s returned %d items, want %d: %v", v.name, len(got), len(wantLevels), got)
			}
			for id, lvl := range wantLevels {
				if g, ok := got[id]; !ok || g != lvl {
					t.Errorf("/sync/items as %s: %s ageLevel = %d (present=%v), want %d", v.name, id, g, ok, lvl)
				}
			}
		})
	}
	for _, p := range []string{"/sync/status", "/sync/deleted?since=0", "/sync/heartbeat"} {
		t.Run(p, func(t *testing.T) {
			if r := w.get(enfViewers[0], p); r.code != http.StatusOK {
				t.Errorf("%s as kid = %d %s: sync replication must not be refused", p, r.code, r.raw)
			}
		})
	}
}

// ── 6. Exempt routes ────────────────────────────────────────────────────────────────────

func TestFR250_ExemptRoutesNeedNeitherAuthNorProfile(t *testing.T) {
	// given: an adult-minted session for the R title
	w := newEnfWorld(t)
	sid := w.mintSession(t, enfViewers[2], enfMovR)
	// when: /playback/{sid}/stream is requested with NO Authorization and NO profile header
	req := httptest.NewRequest("GET", "/playback/"+sid+"/stream", nil)
	rec := httptest.NewRecorder()
	w.h.ServeHTTP(rec, req)
	// then: the capability model answers with the bytes of the title the session names
	if rec.Code != http.StatusOK || rec.Body.String() != "BYTES-OF-"+enfMovR {
		t.Fatalf("exempt playback stream = %d %q", rec.Code, rec.Body.String())
	}
	// images: public artwork, a missing image is its own 404, never a profile error
	req = httptest.NewRequest("GET", "/images/"+enfMovR, nil)
	rec = httptest.NewRecorder()
	w.h.ServeHTTP(rec, req)
	if rec.Code == http.StatusForbidden || rec.Code == http.StatusUnauthorized {
		t.Errorf("/images must stay exempt, got %d", rec.Code)
	}
}

// mintSession starts a playback session as v and returns its id.
func (w *enfWorld) mintSession(t *testing.T, v enfViewerSpec, itemID string) string {
	t.Helper()
	r := w.get(v, "/items/"+itemID+"/playback")
	if r.code != http.StatusOK {
		t.Fatalf("mint session for %s as %s: %d %s", itemID, v.name, r.code, r.raw)
	}
	sid := r.str("sessionId")
	if sid == "" {
		t.Fatalf("playback response has no sessionId: %s", r.raw)
	}
	return sid
}
