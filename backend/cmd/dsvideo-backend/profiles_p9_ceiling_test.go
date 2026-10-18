package main

// P9 shift 2 (FRD-002 oracle coverage): the ceiling, session and settings assertions the
// earlier suites exercised only at level 1 or only for the owner. Every test drives the REAL
// router with a signed JWT and reads the HTTP answer a client reads (plus the DB rows a
// refusal must NOT have written). Expected values are literal tables: the fixture below
// names, per ceiling level, exactly which ids are visible and which are hidden.
//
// Library (one per rung of the ladder, plus unrated; ids are unique tokens):
//   movies  P9M1 G · P9M2 PG · P9M3 PG-13 · P9M4 R · P9MU (NULL certification)
//   shows   P9S1 TV-G · P9S2 TV-PG · P9S3 TV-14 · P9S4 TV-MA · P9SU (NULL); two episodes each,
//           episode ids P9E<n>a / P9E<n>b (P9EUa / P9EUb for the unrated show)

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

const p9Pin = "4821"

var (
	// Visible to a ceiling of 1, 2, 3 (literal; level 4 sees everything incl. unrated).
	p9VisibleMovies = map[int][]string{
		1: {"P9M1"},
		2: {"P9M1", "P9M2"},
		3: {"P9M1", "P9M2", "P9M3"},
	}
	p9HiddenMovies = map[int][]string{
		1: {"P9M2", "P9M3", "P9M4", "P9MU"},
		2: {"P9M3", "P9M4", "P9MU"},
		3: {"P9M4", "P9MU"},
	}
	p9VisibleEpisodes = map[int][]string{
		1: {"P9E1a", "P9E1b"},
		2: {"P9E1a", "P9E1b", "P9E2a", "P9E2b"},
		3: {"P9E1a", "P9E1b", "P9E2a", "P9E2b", "P9E3a", "P9E3b"},
	}
	p9HiddenEpisodes = map[int][]string{
		1: {"P9E2a", "P9E2b", "P9E3a", "P9E3b", "P9E4a", "P9E4b", "P9EUa", "P9EUb"},
		2: {"P9E3a", "P9E3b", "P9E4a", "P9E4b", "P9EUa", "P9EUb"},
		3: {"P9E4a", "P9E4b", "P9EUa", "P9EUb"},
	}
	p9HiddenShows = map[int][]string{
		1: {"P9S2", "P9S3", "P9S4", "P9SU"},
		2: {"P9S3", "P9S4", "P9SU"},
		3: {"P9S4", "P9SU"},
	}
	p9VisibleShows = map[int][]string{
		1: {"P9S1"},
		2: {"P9S1", "P9S2"},
		3: {"P9S1", "P9S2", "P9S3"},
	}
)

type p9World struct {
	*qaEnv
	owner string
	lvl   map[int]string // restricted profile id by ceiling 1..3
	adult string         // non-owner profile at level 4
}

// newP9World is the standard family: owner plus ceilings 1, 2 and 3 (the account's profile
// limit is 4, so a non-owner Adult profile needs newP9WorldWith).
func newP9World(t *testing.T) *p9World {
	t.Helper()
	return newP9WorldWith(t, []int{1, 2, 3}, false)
}

func newP9WorldWith(t *testing.T, levels []int, withAdult bool) *p9World {
	t.Helper()
	e := newQAEnv(t)
	root := t.TempDir()
	movies, tv := filepath.Join(root, "movies"), filepath.Join(root, "tv")
	e.s.cfg.MoviesPath, e.s.cfg.TVPath = movies, tv
	e.s.playSessions = map[string]PlaySession{} // main() builds this; the bare test Server does not

	seedMovie := func(id string, cert *string) {
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
			VALUES(?, 'lib_movies', 'movie', ?, ?, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 'Drama', ?, 'h264', 'aac', 'mp4', 0, 5400)`,
			id, id, p, cert)
		if err != nil {
			t.Fatalf("seed %s: %v", id, err)
		}
	}
	seedMovie("P9M1", sp("G"))
	seedMovie("P9M2", sp("PG"))
	seedMovie("P9M3", sp("PG-13"))
	seedMovie("P9M4", sp("R"))
	seedMovie("P9MU", nil)

	shows := []struct {
		show, epPrefix string
		cert           *string
	}{
		{"P9S1", "P9E1", sp("TV-G")}, {"P9S2", "P9E2", sp("TV-PG")}, {"P9S3", "P9E3", sp("TV-14")},
		{"P9S4", "P9E4", sp("TV-MA")}, {"P9SU", "P9EU", nil},
	}
	for _, sh := range shows {
		for i, suffix := range []string{"a", "b"} {
			p := filepath.Join(tv, sh.show, fmt.Sprintf("S01E%02d.mkv", i+1))
			_, err := e.db.Exec(`INSERT INTO items(id, library_id, type, title, path, show_name, season_number, episode_number, added_at, updated_at, content_rating, duration_seconds)
				VALUES(?, 'lib_tv', 'episode', ?, ?, ?, 1, ?, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', ?, 1800)`,
				sh.epPrefix+suffix, sh.epPrefix+suffix, p, sh.show, i+1, sh.cert)
			if err != nil {
				t.Fatalf("seed episode %s%s: %v", sh.epPrefix, suffix, err)
			}
		}
	}

	w := &p9World{qaEnv: e, lvl: map[int]string{}}
	w.owner = e.setOwnerPin(qaAlice, p9Pin)
	names := map[int]string{1: "Little Kids", 2: "Older Kids", 3: "Teens"}
	for _, l := range levels {
		w.lvl[l] = e.mustCreate(qaAlice, p9Pin, names[l], l, nil)
	}
	if withAdult {
		w.adult = e.mustCreate(qaAlice, p9Pin, "Grownup", 4, nil)
	}
	return w
}

// ids reads data["items"][*].id from a list answer, in answer order.
func (r qaResp) itemIDs() []string {
	raw, _ := r.js["items"].([]any)
	out := make([]string, 0, len(raw))
	for _, it := range raw {
		m, _ := it.(map[string]any)
		id, _ := m["id"].(string)
		out = append(out, id)
	}
	return out
}

func sortedCopy(in []string) []string {
	out := append([]string{}, in...)
	sort.Strings(out)
	return out
}

func concat(parts ...[]string) []string {
	var out []string
	for _, p := range parts {
		out = append(out, p...)
	}
	return out
}

// pageAll walks base (a path that already has a query string) with limit=N&offset=k until a
// page comes back empty, asserting the reported total on every page. It returns every id in
// the order served. The walk is capped so a handler that never ends cannot hang the suite.
func (w *p9World) pageAll(profile, base string, limit int, wantTotal int) []string {
	w.t.Helper()
	var all []string
	for off, pages := 0, 0; pages < 50; off, pages = off+limit, pages+1 {
		r := w.do(qaAlice, "GET", fmt.Sprintf("%s&limit=%d&offset=%d", base, limit, off), "", profile)
		if r.code != http.StatusOK {
			w.t.Fatalf("GET %s offset %d = %d %s", base, off, r.code, r.raw)
		}
		if got := r.num("total"); got != wantTotal {
			w.t.Errorf("GET %s offset %d: total = %d, want %d (the visible count on EVERY page)", base, off, got, wantTotal)
		}
		ids := r.itemIDs()
		if len(ids) == 0 {
			return all
		}
		all = append(all, ids...)
	}
	w.t.Fatalf("GET %s never returned an empty page", base)
	return nil
}

// assertSameSet fails unless got is exactly want (as sets) and holds no id twice.
func assertSameSet(t *testing.T, what string, got, want []string) {
	t.Helper()
	g, wnt := sortedCopy(got), sortedCopy(want)
	if strings.Join(g, ",") != strings.Join(wnt, ",") {
		t.Errorf("%s = %v, want exactly %v (each id once)", what, g, wnt)
	}
}

// ── OC-2136: /items listings at levels 2 and 3, paging included ─────────────────────────

// Mutation: delete the v.andVisible(...) call in handleItems -> every level fails on the
// hidden ids and the total.
func TestOC2136_ItemListingsHoldToTheCeilingAtEveryLevelAcrossPages(t *testing.T) {
	// given: one library with a title at every rung plus unrated, and a profile per ceiling
	w := newP9World(t)
	for _, level := range []int{1, 2, 3} {
		hdr := w.lvl[level]
		t.Run(fmt.Sprintf("level_%d", level), func(t *testing.T) {
			// when: the movie library is paged one row at a time, and the TV library two at a time
			movies := w.pageAll(hdr, "/items?libraryId=lib_movies", 1, len(p9VisibleMovies[level]))
			eps := w.pageAll(hdr, "/items?libraryId=lib_tv", 2, len(p9VisibleEpisodes[level]))
			// then: the union of pages is exactly the visible set, each id once
			assertSameSet(t, "movie pages", movies, p9VisibleMovies[level])
			assertSameSet(t, "episode pages", eps, p9VisibleEpisodes[level])
			if len(movies) != len(p9VisibleMovies[level]) || len(eps) != len(p9VisibleEpisodes[level]) {
				t.Errorf("pages served %d movies / %d episodes, want %d / %d (a repeated id means unstable paging)",
					len(movies), len(eps), len(p9VisibleMovies[level]), len(p9VisibleEpisodes[level]))
			}
			// one past the end: an offset beyond the visible set is an empty page, not a hidden row
			past := w.do(qaAlice, "GET", fmt.Sprintf("/items?libraryId=lib_movies&limit=5&offset=%d", len(p9VisibleMovies[level])), "", hdr)
			wantOK(t, past, 200)
			if got := past.itemIDs(); len(got) != 0 {
				t.Errorf("offset past the visible set returned %v, want none", got)
			}
			// every row carries an ageLevel at or below the ceiling
			full := w.do(qaAlice, "GET", "/items?libraryId=lib_movies", "", hdr)
			for _, it := range full.js["items"].([]any) {
				if lv := it.(map[string]any)["ageLevel"].(float64); int(lv) > level {
					t.Errorf("item %v has ageLevel %v above ceiling %d", it.(map[string]any)["id"], lv, level)
				}
			}
		})
	}
}

// justAdded and justWatched are the other two /items modes (continue-watching and
// recently-played rails read the same visible set).
// Mutation: drop the ceiling from handleItemsJustWatched's WHERE, or from the justAdded
// branch (it shares handleItems' andVisible) -> the matching subtest fails.
func TestOC2136_JustAddedAndJustWatchedModesHoldToTheCeiling(t *testing.T) {
	// given: every title has progress under every restricted profile (a restricted profile may write progress at any level, FR-231)
	w := newP9World(t)
	all := concat(p9VisibleMovies[3], p9HiddenMovies[3])
	for _, level := range []int{1, 2, 3} {
		for _, id := range all {
			r := w.do(qaAlice, "POST", "/items/"+id+"/progress", `{"positionSeconds":60,"durationSeconds":1000}`, w.lvl[level])
			if r.code != http.StatusOK {
				t.Fatalf("seed progress %s under level %d: %d %s", id, level, r.code, r.raw)
			}
		}
	}
	for _, level := range []int{1, 2, 3} {
		hdr := w.lvl[level]
		t.Run(fmt.Sprintf("justAdded/level_%d", level), func(t *testing.T) {
			r := w.do(qaAlice, "GET", "/items?libraryId=lib_movies&filter=justAdded", "", hdr)
			wantOK(t, r, 200)
			assertSameSet(t, "justAdded", r.itemIDs(), p9VisibleMovies[level])
		})
		t.Run(fmt.Sprintf("justWatched/level_%d", level), func(t *testing.T) {
			got := w.pageAll(hdr, "/items?libraryId=lib_movies&filter=justWatched", 1, len(p9VisibleMovies[level]))
			assertSameSet(t, "justWatched pages", got, p9VisibleMovies[level])
		})
	}
	// the progress reads (continue-watching) are filtered the same way
	for _, level := range []int{1, 2, 3} {
		t.Run(fmt.Sprintf("progress_all/level_%d", level), func(t *testing.T) {
			r := w.do(qaAlice, "GET", "/progress/all", "", w.lvl[level])
			wantOK(t, r, 200)
			for _, id := range p9HiddenMovies[level] {
				if r.mentions(`"`+id+`"`) {
					t.Errorf("/progress/all under level %d names hidden %s: %s", level, id, r.raw)
				}
			}
			for _, id := range p9VisibleMovies[level] {
				if !r.mentions(`"` + id + `"`) {
					t.Errorf("/progress/all under level %d lost visible %s: %s", level, id, r.raw)
				}
			}
		})
	}
}

// ── OC-2137: search at levels 2 and 3, paging included ──────────────────────────────────

// Mutation: delete the visFrag from handleSearch's count or row query -> total/ids fail.
func TestOC2137_SearchHoldsToTheCeilingAtEveryLevelAcrossPages(t *testing.T) {
	// given: the term "P9" matches a title at every level
	w := newP9World(t)
	for _, level := range []int{1, 2, 3} {
		t.Run(fmt.Sprintf("level_%d", level), func(t *testing.T) {
			want := concat(p9VisibleMovies[level], p9VisibleEpisodes[level])
			// when: paged two rows at a time
			got := w.pageAll(w.lvl[level], "/search?q=P9", 2, len(want))
			// then
			assertSameSet(t, "search pages", got, want)
			if len(got) != len(want) {
				t.Errorf("search served %d rows over its pages, want %d (a repeat means unstable paging)", len(got), len(want))
			}
			// hidden titles are not findable even by exact title
			for _, id := range concat(p9HiddenMovies[level], p9HiddenEpisodes[level]) {
				r := w.do(qaAlice, "GET", "/search?q="+id, "", w.lvl[level])
				wantOK(t, r, 200)
				if r.num("total") != 0 || len(r.itemIDs()) != 0 {
					t.Errorf("exact-title search for hidden %s under level %d = %s, want total 0", id, level, r.raw)
				}
			}
		})
	}
}

// ── OC-2132 / OC-2133: unrated is hidden below Adult, shown to every Adult profile ───────

// Mutation: make the SQL ladder map NULL to a level <= 3 (or the item gate treat NULL as
// visible) -> U appears in a listing or GET /items/P9MU answers 200.
func TestOC2132_UnratedIsHiddenAndRefusedAtLevels1To3(t *testing.T) {
	// given: unrated movie P9MU and unrated show P9SU (episodes P9EUa/b)
	w := newP9World(t)
	for _, level := range []int{1, 2, 3} {
		hdr := w.lvl[level]
		t.Run(fmt.Sprintf("level_%d", level), func(t *testing.T) {
			list := w.do(qaAlice, "GET", "/items?libraryId=lib_movies", "", hdr)
			wantOK(t, list, 200)
			if len(list.itemIDs()) == 0 {
				t.Fatalf("listing is empty: a blank answer proves nothing: %s", list.raw)
			}
			for _, id := range list.itemIDs() {
				if id == "P9MU" {
					t.Errorf("unrated P9MU listed under level %d", level)
				}
			}
			tv := w.do(qaAlice, "GET", "/items?libraryId=lib_tv", "", hdr)
			for _, id := range tv.itemIDs() {
				if id == "P9EUa" || id == "P9EUb" {
					t.Errorf("unrated episode %s listed under level %d", id, level)
				}
			}
			s := w.do(qaAlice, "GET", "/search?q=P9MU", "", hdr)
			if s.num("total") != 0 || len(s.itemIDs()) != 0 {
				t.Errorf("search for the unrated title under level %d = %s, want nothing", level, s.raw)
			}
			wantErr(t, w.do(qaAlice, "GET", "/items/P9MU", "", hdr), 403, "content_restricted")
			wantErr(t, w.do(qaAlice, "GET", "/items/P9EUa", "", hdr), 403, "content_restricted")
		})
	}
}

// Only the owner was tested at level 4; a NON-owner Adult profile is subject to the same rule.
// Mutation: treat "unrestricted" as isOwner instead of level 4 (Visible/Restricted) -> the
// grownup loses P9MU and the playback source.
func TestOC2133_NonOwnerAdultProfileSeesUnratedAndMayPlayIt(t *testing.T) {
	// given: unrated P9MU, the owner, a non-owner level-4 profile and a Teens profile
	w := newP9WorldWith(t, []int{3}, true)
	for name, hdr := range map[string]string{"owner": w.owner, "non_owner_adult": w.adult} {
		t.Run(name, func(t *testing.T) {
			list := w.do(qaAlice, "GET", "/items?libraryId=lib_movies", "", hdr)
			assertSameSet(t, "movie listing", list.itemIDs(), []string{"P9M1", "P9M2", "P9M3", "P9M4", "P9MU"})
			s := w.do(qaAlice, "GET", "/search?q=P9MU", "", hdr)
			assertSameSet(t, "search P9MU", s.itemIDs(), []string{"P9MU"})
			pb := w.do(qaAlice, "GET", "/items/P9MU/playback", "", hdr)
			wantOK(t, pb, 200)
			if pb.str("sessionId") == "" {
				t.Errorf("playback of the unrated title returned no session: %s", pb.raw)
			}
		})
	}
	// negative control: the level just below Adult is still refused (the rule is the ceiling, not the title)
	wantErr(t, w.do(qaAlice, "GET", "/items/P9MU/playback", "", w.lvl[3]), 403, "content_restricted")
}

// ── OC-2143: every item-scoped route refuses a hidden title, at levels 2 and 3 ───────────

// Mutation: remove refuseAboveCeiling from handleItemDetail / handlePlayback / trickplay, or
// gateShow from a show route -> that route's subtests go red.
func TestOC2143_HiddenTitleRoutesAnswerContentRestrictedAtEveryLevel(t *testing.T) {
	// given: titles above each ceiling
	w := newP9World(t)
	for _, level := range []int{1, 2, 3} {
		hdr := w.lvl[level]
		for _, id := range p9HiddenMovies[level] {
			for _, path := range []string{
				"/items/" + id, "/items/" + id + "/playback",
				"/trickplay/" + id + "/trickplay.vtt", "/trickplay/" + id + "/trickplay.jpg",
			} {
				t.Run(fmt.Sprintf("level_%d%s", level, path), func(t *testing.T) {
					wantErr(t, w.do(qaAlice, "GET", path, "", hdr), 403, "content_restricted")
				})
			}
		}
		for _, show := range p9HiddenShows[level] {
			for _, path := range []string{"/shows/" + show, "/tv/shows/" + show + "/seasons", "/tv/shows/" + show + "/episodes"} {
				t.Run(fmt.Sprintf("level_%d%s", level, path), func(t *testing.T) {
					wantErr(t, w.do(qaAlice, "GET", path, "", hdr), 403, "content_restricted")
				})
			}
		}
		// then, paired: the titles the profile MAY see are served (a blanket 403 proves nothing)
		for _, id := range p9VisibleMovies[level] {
			t.Run(fmt.Sprintf("level_%d_visible/%s", level, id), func(t *testing.T) {
				wantOK(t, w.do(qaAlice, "GET", "/items/"+id, "", hdr), 200)
				wantOK(t, w.do(qaAlice, "GET", "/items/"+id+"/playback", "", hdr), 200)
			})
		}
		for _, show := range p9VisibleShows[level] {
			t.Run(fmt.Sprintf("level_%d_visible/%s", level, show), func(t *testing.T) {
				wantOK(t, w.do(qaAlice, "GET", "/tv/shows/"+show+"/episodes", "", hdr), 200)
				wantOK(t, w.do(qaAlice, "GET", "/shows/"+show, "", hdr), 200)
			})
		}
	}
}

// ── OC-2144: refused adds leave the stores untouched ─────────────────────────────────────

// Mutation: remove the refuseAboveCeiling call from handleAddPlaylistItem or handleAddDownload
// (watchlist add is the control that already asserted this) -> the row count moves.
func TestOC2144_RefusedPlaylistAndDownloadAddsStoreNothing(t *testing.T) {
	// given: an owner playlist, and a profile at each ceiling
	w := newP9World(t)
	pl := w.do(qaAlice, "POST", "/playlists", `{"title":"Family night"}`, w.owner)
	if pl.code != http.StatusOK && pl.code != http.StatusCreated {
		t.Fatalf("seed playlist: %d %s", pl.code, pl.raw)
	}
	playlistID := pl.str("id")
	if playlistID == "" {
		t.Fatalf("seed playlist: no id in %s", pl.raw)
	}
	counts := func() (watch, playlist, downloads int) {
		return w.count(`SELECT COUNT(*) FROM watchlist`),
			w.count(`SELECT COUNT(*) FROM playlist_items WHERE playlist_id = ?`, playlistID),
			w.count(`SELECT COUNT(*) FROM downloads`)
	}
	for _, level := range []int{1, 2, 3} {
		hdr := w.lvl[level]
		for _, id := range p9HiddenMovies[level] {
			t.Run(fmt.Sprintf("level_%d/%s", level, id), func(t *testing.T) {
				wBefore, pBefore, dBefore := counts()
				// when
				rw := w.do(qaAlice, "POST", "/watchlist/"+id, "", hdr)
				rp := w.do(qaAlice, "POST", "/playlists/"+playlistID+"/items", jb(map[string]any{"itemId": id}), hdr)
				rd := w.do(qaAlice, "POST", "/downloads/"+id, "", hdr)
				// then
				wantErr(t, rw, 403, "content_restricted")
				wantErr(t, rp, 403, "content_restricted")
				wantErr(t, rd, 403, "content_restricted")
				wAfter, pAfter, dAfter := counts()
				if wAfter != wBefore || pAfter != pBefore || dAfter != dBefore {
					t.Errorf("counts watchlist/playlist/downloads %d/%d/%d -> %d/%d/%d, want unchanged",
						wBefore, pBefore, dBefore, wAfter, pAfter, dAfter)
				}
			})
		}
	}
	// positive control: a title the profile may see IS stored (counts can move)
	wBefore, pBefore, dBefore := counts()
	wantOK(t, w.do(qaAlice, "POST", "/watchlist/P9M1", "", w.lvl[2]), 200)
	wantOK(t, w.do(qaAlice, "POST", "/playlists/"+playlistID+"/items", jb(map[string]any{"itemId": "P9M1"}), w.lvl[2]), 200)
	wantOK(t, w.do(qaAlice, "POST", "/downloads/P9M1", "", w.lvl[2]), 200)
	wAfter, pAfter, dAfter := counts()
	if wAfter != wBefore+1 || pAfter != pBefore+1 || dAfter != dBefore+1 {
		t.Errorf("control: counts %d/%d/%d -> %d/%d/%d, want each +1", wBefore, pBefore, dBefore, wAfter, pAfter, dAfter)
	}
}

// ── OC-2145: a refused playback creates no session ───────────────────────────────────────

func (w *p9World) sessionCounts() (live, persisted int) {
	w.s.mu.Lock()
	live = len(w.s.playSessions)
	w.s.mu.Unlock()
	return live, w.count(`SELECT COUNT(*) FROM play_sessions`)
}

// Mutation: move (or delete) refuseAboveCeiling in handlePlayback so it runs after the
// session is stored -> live/persisted counts rise on a refused request.
func TestOC2145_RefusedPlaybackCreatesNoSession(t *testing.T) {
	// given: a profile at each ceiling and the titles above it
	w := newP9World(t)
	for _, level := range []int{1, 2, 3} {
		for _, id := range p9HiddenMovies[level] {
			t.Run(fmt.Sprintf("level_%d/%s", level, id), func(t *testing.T) {
				liveBefore, rowsBefore := w.sessionCounts()
				// when
				r := w.do(qaAlice, "GET", "/items/"+id+"/playback", "", w.lvl[level])
				// then
				wantErr(t, r, 403, "content_restricted")
				if r.str("sessionId") != "" {
					t.Errorf("refusal body carries a sessionId: %s", r.raw)
				}
				liveAfter, rowsAfter := w.sessionCounts()
				if liveAfter != liveBefore || rowsAfter != rowsBefore {
					t.Errorf("sessions live/persisted %d/%d -> %d/%d after a refused playback, want unchanged",
						liveBefore, rowsBefore, liveAfter, rowsAfter)
				}
			})
		}
	}
	// control: an allowed playback DOES mint one (so the counters can move)
	liveBefore, rowsBefore := w.sessionCounts()
	wantOK(t, w.do(qaAlice, "GET", "/items/P9M1/playback", "", w.lvl[1]), 200)
	liveAfter, rowsAfter := w.sessionCounts()
	if liveAfter != liveBefore+1 || rowsAfter != rowsBefore+1 {
		t.Errorf("control: sessions %d/%d -> %d/%d, want +1 each", liveBefore, rowsBefore, liveAfter, rowsAfter)
	}
}

// ── OC-2147: restricted profiles cannot run metadata tools; nothing changes ──────────────

// Mutation: drop requireUnrestricted from the tmdb-fix routes -> the fake TMDb is called and
// the row is rewritten (title M501, rating R), so both the 403 and the snapshot go red.
func TestOC2147_RestrictedProfilesCannotChangeMetadata(t *testing.T) {
	// given: a configured TMDb that WOULD re-match the items, and one row of each kind
	w := newP9World(t)
	fake := newFakeTMDb(t, func(p string, _ url.Values) (int, string) {
		switch p {
		case "/movie/501":
			return 200, movieJSON(501, "R")
		case "/tv/601":
			return 200, tvJSON(601, "TV-MA")
		}
		return 404, `{}`
	})
	w.s.tmdbMu.Lock()
	w.s.tmdbClient = fake.client()
	w.s.tmdbMu.Unlock()

	snapshot := func() string {
		var out []string
		for _, id := range []string{"P9M1", "P9E1a"} {
			var title string
			var cert, genres *string
			var seq int64
			if err := w.db.QueryRow(`SELECT title, content_rating, genres, COALESCE(change_seq,0) FROM items WHERE id = ?`, id).Scan(&title, &cert, &genres, &seq); err != nil {
				t.Fatalf("snapshot %s: %v", id, err)
			}
			c, g := "<nil>", "<nil>"
			if cert != nil {
				c = *cert
			}
			if genres != nil {
				g = *genres
			}
			out = append(out, fmt.Sprintf("%s|%s|%s|%s|%d", id, title, c, g, seq))
		}
		return strings.Join(out, ";")
	}
	routes := []struct{ method, path, body string }{
		{"GET", "/items/P9M1/tmdb-search?q=x", ""},
		{"POST", "/items/P9M1/tmdb-fix", `{"tmdbId":501,"type":"movie"}`},
		{"GET", "/tv/shows/P9S1/tmdb-search?q=x", ""},
		{"POST", "/tv/shows/P9S1/tmdb-fix", `{"tmdbId":601}`},
		{"POST", "/items/P9E1a/tmdb-fix", `{"tmdbId":601,"type":"tv"}`},
		{"GET", "/admin/status", ""},
		{"POST", "/admin/scan", ""},
	}
	for _, level := range []int{1, 2, 3} {
		for _, rt := range routes {
			t.Run(fmt.Sprintf("level_%d/%s%s", level, rt.method, rt.path), func(t *testing.T) {
				before := snapshot()
				calls := len(fake.snapshot())
				r := w.do(qaAlice, rt.method, rt.path, rt.body, w.lvl[level])
				wantErr(t, r, 403, "profile_restricted")
				if after := snapshot(); after != before {
					t.Errorf("rows changed by a refused call:\n before %s\n after  %s", before, after)
				}
				if got := len(fake.snapshot()); got != calls {
					t.Errorf("refused call reached TMDb %d time(s)", got-calls)
				}
			})
		}
	}
	// control: the owner's identical fix is NOT refused, reaches TMDb and rewrites the row,
	// so the "unchanged" assertions above could have failed.
	before := snapshot()
	r := w.do(qaAlice, "POST", "/items/P9M1/tmdb-fix", `{"tmdbId":501,"type":"movie"}`, w.owner)
	if r.code == http.StatusForbidden {
		t.Fatalf("control: owner tmdb-fix refused: %s", r.raw)
	}
	if snapshot() == before {
		t.Errorf("control: owner tmdb-fix (status %d %s) did not change the row; the unchanged-row checks above prove nothing", r.code, r.raw)
	}
}

// ── OC-2154: stopping a session is not profile-gated ─────────────────────────────────────

// Mutation: copy playSessionProfileAllowed's refusal onto handlePlaybackStop -> the stop
// under a different profile answers 403 and the session survives.
func TestOC2154_StopUnderAnotherProfileIsNotRefused(t *testing.T) {
	// given: a session minted under the owner and an unrelated kid profile
	w := newP9World(t)
	pb := w.do(qaAlice, "GET", "/items/P9M1/playback", "", w.owner)
	wantOK(t, pb, 200)
	sid := pb.str("sessionId")
	if sid == "" {
		t.Fatalf("no sessionId: %s", pb.raw)
	}
	if live, rows := w.sessionCounts(); live != 1 || rows != 1 {
		t.Fatalf("precondition: sessions live/persisted = %d/%d, want 1/1", live, rows)
	}
	// when: the kid profile's header accompanies the stop
	req := httptest.NewRequest(http.MethodPost, "/playback/"+sid+"/stop", nil)
	req.Header.Set(profileHeader, w.lvl[1])
	rec := httptest.NewRecorder()
	w.h.ServeHTTP(rec, req)
	// then: 2xx, and the session is gone from memory and from the table
	if rec.Code < 200 || rec.Code > 299 {
		t.Errorf("stop under another profile = %d %s, want 2xx", rec.Code, rec.Body.String())
	}
	if live, rows := w.sessionCounts(); live != 0 || rows != 0 {
		t.Errorf("after stop sessions live/persisted = %d/%d, want 0/0", live, rows)
	}
}

// ── OC-2161: lowering a ceiling mid-stream ───────────────────────────────────────────────

// Mutation: have playSessionProfileAllowed / the stream route re-check the CURRENT ceiling
// (itemAboveCeiling) -> the live session stops serving (first assertion); or remove the
// gate from handlePlayback -> the new session is minted (second assertion).
func TestOC2161_LoweringTheCeilingMidStreamKeepsTheLiveSessionButRefusesNewOnes(t *testing.T) {
	// given: the Teens profile (level 3) is streaming a PG-13 title
	w := newP9World(t)
	teen := w.lvl[3]
	sid := w.do(qaAlice, "GET", "/items/P9M3/playback", "", teen).str("sessionId")
	if sid == "" {
		t.Fatal("teen could not start a PG-13 session")
	}
	stream := "/playback/" + sid + "/stream"
	get := func() *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, stream, nil)
		req.Header.Set(profileHeader, teen)
		rec := httptest.NewRecorder()
		w.h.ServeHTTP(rec, req)
		return rec
	}
	if rec := get(); rec.Code != http.StatusOK || rec.Body.String() != "BYTES-OF-P9M3" {
		t.Fatalf("precondition: stream = %d %q", rec.Code, rec.Body.String())
	}

	// when: the owner lowers the profile to Little Kids
	wantOK(t, w.do(qaAlice, "PATCH", "/profiles/"+teen, jb(map[string]any{"ownerPin": p9Pin, "maxAgeLevel": 1}), ""), 200)

	// then: the current session keeps serving its bytes ...
	if rec := get(); rec.Code != http.StatusOK || rec.Body.String() != "BYTES-OF-P9M3" {
		t.Errorf("live session after lowering = %d %q, want 200 + bytes (FR-252)", rec.Code, rec.Body.String())
	}
	// ... while a NEW session for the same title is refused and creates nothing
	live, rows := w.sessionCounts()
	wantErr(t, w.do(qaAlice, "GET", "/items/P9M3/playback", "", teen), 403, "content_restricted")
	if l2, r2 := w.sessionCounts(); l2 != live || r2 != rows {
		t.Errorf("sessions %d/%d -> %d/%d after the refused new session, want unchanged", live, rows, l2, r2)
	}
}

// ── OC-2012: resume position is the viewing profile's ────────────────────────────────────

// Mutation: in handlePlayback read the resume point with the account/owner profile instead
// of v.ProfileID -> B's response carries A's 1200.
func TestOC2012_PlaybackResumeIsThePlayingProfilesNotAnotherProfiles(t *testing.T) {
	// given: the owner (A) has 1200s on P9M1; the Little Kids profile (B) has none
	w := newP9World(t)
	wantOK(t, w.do(qaAlice, "POST", "/items/P9M1/progress", `{"positionSeconds":1200,"durationSeconds":5400}`, w.owner), 200)

	// when/then: A resumes at 1200 (so the field can carry it) ...
	a := w.do(qaAlice, "GET", "/items/P9M1/playback", "", w.owner)
	wantOK(t, a, 200)
	if a.num("resumePositionSeconds") != 1200 {
		t.Fatalf("control: owner resume = %v, want 1200 in %s", a.js["resumePositionSeconds"], a.raw)
	}
	// ... B starts from the beginning
	b := w.do(qaAlice, "GET", "/items/P9M1/playback", "", w.lvl[1])
	wantOK(t, b, 200)
	if v, present := b.js["resumePositionSeconds"]; present && v != float64(0) {
		t.Errorf("profile B resume = %v, want absent or 0, never A's 1200: %s", v, b.raw)
	}
}

// ── OC-2094: a PIN-locked profile is served without per-request PIN proof ────────────────

// Pins the DOCUMENTED accepted gap (FR-223): the PIN is a client-side lock; the server does
// not ask for proof on each request. If the server ever starts demanding it, this test goes
// red and the FRD must change in the same commit.
// Mutation: make profileResolver answer 403/401 for hasPin profiles without a verified
// session -> GET /items is no longer 200.
func TestOC2094_PinnedProfileIsServedWithoutPerRequestPinProof(t *testing.T) {
	// given: Kid B with a PIN that was never verified in this session
	w := newP9WorldWith(t, nil, false)
	pinned := w.mustCreate(qaAlice, p9Pin, "Pinned", 1, map[string]any{"pin": "1111"})
	if p := w.profileByName(qaAlice, "Pinned"); p == nil || p["hasPin"] != true {
		t.Fatalf("precondition: Pinned profile hasPin = %v", p)
	}
	// when
	r := w.do(qaAlice, "GET", "/items?libraryId=lib_movies", "", pinned)
	// then: served, and filtered to B's ceiling
	wantOK(t, r, 200)
	assertSameSet(t, "pinned profile's movie listing", r.itemIDs(), []string{"P9M1"})
}

// ── OC-2097: settings are per account, not per profile ───────────────────────────────────

// Mutation: key the settings row by the profile header (handlePutSettings userID := profile)
// -> B reads nothing.
func TestOC2097_SettingsBelongToTheAccountAndAreSharedAcrossProfiles(t *testing.T) {
	// given: profiles A (owner) and B (Little Kids) on one account
	w := newP9World(t)
	// when: A writes a setting
	wantOK(t, w.do(qaAlice, "PUT", "/settings", `{"settings":{"p9_theme":"midnight"}}`, w.owner), 200)
	// then: B reads A's value, there is one row for the account, and another account sees none
	r := w.do(qaAlice, "GET", "/settings", "", w.lvl[1])
	wantOK(t, r, 200)
	settings, _ := r.js["settings"].(map[string]any)
	if settings["p9_theme"] != "midnight" {
		t.Errorf("profile B reads settings %v, want p9_theme=midnight (per account)", settings)
	}
	if n := w.count(`SELECT COUNT(*) FROM settings WHERE key = 'p9_theme' AND user_id = ?`, qaAlice.id); n != 1 {
		t.Errorf("settings rows for the account = %d, want 1", n)
	}
	other := w.do(qaBob, "GET", "/settings", "", "")
	wantOK(t, other, 200)
	if s, _ := other.js["settings"].(map[string]any); s["p9_theme"] != nil {
		t.Errorf("another account reads %v, want no p9_theme", s)
	}
	// and the reverse direction: B's write is visible to A
	wantOK(t, w.do(qaAlice, "PUT", "/settings", `{"settings":{"p9_theme":"dawn"}}`, w.lvl[1]), 200)
	back := w.do(qaAlice, "GET", "/settings", "", w.owner)
	if s, _ := back.js["settings"].(map[string]any); s["p9_theme"] != "dawn" {
		t.Errorf("owner reads %v after B's write, want dawn", s)
	}
}

// ── OC-2124: contentRating is the stored string, verbatim ────────────────────────────────

// Mutation: normalize or collapse contentRating in putRating (e.g. return "TV-Y7") -> red.
func TestOC2124_ContentRatingIsReturnedRawWithItsDerivedAgeLevel(t *testing.T) {
	// given: titles stored with variant-suffix and mixed-case certifications
	w := newP9World(t)
	cases := []struct {
		id, stored string
		ageLevel   float64
	}{
		{"P9RawFV", "TV-Y7-FV", 2},
		{"P9RawLower", "tv-y7-fv", 2},
		{"P9RawNC", "NC-17", 4},
	}
	for _, c := range cases {
		w.seedItem(c.id, "Drama", sp(c.stored))
	}
	for _, c := range cases {
		t.Run(c.stored, func(t *testing.T) {
			// when
			detail := w.do(qaAlice, "GET", "/items/"+c.id, "", w.owner)
			wantOK(t, detail, 200)
			// then: raw string, derived level
			if detail.js["contentRating"] != c.stored || detail.js["ageLevel"] != c.ageLevel {
				t.Errorf("detail contentRating/ageLevel = %v/%v, want %q/%v", detail.js["contentRating"], detail.js["ageLevel"], c.stored, c.ageLevel)
			}
			list := w.do(qaAlice, "GET", "/items?libraryId=lib1", "", w.owner)
			var found bool
			for _, it := range list.js["items"].([]any) {
				m := it.(map[string]any)
				if m["id"] == c.id {
					found = true
					if m["contentRating"] != c.stored || m["ageLevel"] != c.ageLevel {
						t.Errorf("list contentRating/ageLevel = %v/%v, want %q/%v", m["contentRating"], m["ageLevel"], c.stored, c.ageLevel)
					}
				}
			}
			if !found {
				t.Errorf("%s missing from /items?libraryId=lib1: %s", c.id, list.raw)
			}
		})
	}
}

// ── OC-2211: a collection's artwork never comes from a title hidden from the profile ──────

// A kid seeing adult artwork on a collection tile is the real-world failure FR-275 exists to
// prevent. Hidden titles are made the NEWEST members and carry posters, so any code path that
// picks "newest member with a poster" before the ceiling is applied picks one of them.
//
// Mutation: remove `visFrag` from collectionMembers' WHERE (or build the poster pick from a
// second, unfiltered query) -> posterImageId becomes a hidden id and itemCount grows.
func TestOC2211_CollectionPosterNeverComesFromAHiddenTitle(t *testing.T) {
	// given: Disney members at every rung + unrated + a TV-MA show, ascending addedAt so the
	// hidden ones are newest; every one has a poster
	e := newColEnv(t)
	members := []struct {
		id   string
		cert *string
	}{
		{"D1", sp("G")}, {"D2", sp("PG")}, {"D3", sp("PG-13")}, {"D4", sp("R")}, {"DU", nil},
	}
	for i, m := range members {
		e.movie(m.id, "Drama", m.cert, i+1)
		e.tagCompany(m.id, tagKindCompany, 2) // Walt Disney Pictures
	}
	for i, suffix := range []string{"a", "b"} {
		id := "DS" + suffix
		e.episode(id, "DarkShow", "Drama", sp("TV-MA"), 6+i)
		e.tagCompany(id, tagKindCompany, 2)
	}
	for _, id := range []string{"D1", "D2", "D3", "D4", "DU", "DSa", "DSb"} {
		if _, err := e.db.Exec(`UPDATE items SET poster_path='/p.jpg' WHERE id=?`, id); err != nil {
			t.Fatal(err)
		}
	}
	profiles := map[int]string{1: e.mustCreate(qaAlice, "1234", "Tiny", 1, nil), 2: e.kid, 3: e.teen}
	wantPoster := map[int]string{1: "D1", 2: "D2", 3: "D3"} // newest VISIBLE member
	wantCount := map[int]float64{1: 1, 2: 2, 3: 3}
	hidden := map[int][]string{
		1: {"D2", "D3", "D4", "DU", "DSa", "DSb", "DarkShow"},
		2: {"D3", "D4", "DU", "DSa", "DSb", "DarkShow"},
		3: {"D4", "DU", "DSa", "DSb", "DarkShow"},
	}
	for _, level := range []int{1, 2, 3} {
		t.Run(fmt.Sprintf("level_%d", level), func(t *testing.T) {
			// when
			r := e.do(qaAlice, "GET", "/collections", "", profiles[level])
			wantOK(t, r, 200)
			// then: the Disney tile counts and artworks only visible members
			var disney map[string]any
			for _, c := range r.js["collections"].([]any) {
				if m := c.(map[string]any); m["id"] == "disney" {
					disney = m
				}
			}
			if disney == nil {
				t.Fatalf("level %d has no Disney collection: %s", level, r.raw)
			}
			if disney["posterImageId"] != wantPoster[level] {
				t.Errorf("Disney posterImageId = %v, want %q (the newest title this profile may see)", disney["posterImageId"], wantPoster[level])
			}
			if disney["itemCount"] != wantCount[level] {
				t.Errorf("Disney itemCount = %v, want %v", disney["itemCount"], wantCount[level])
			}
			// and no hidden id appears anywhere in the tile list or the member list
			items := e.do(qaAlice, "GET", "/collections/disney/items", "", profiles[level])
			wantOK(t, items, 200)
			for _, h := range hidden[level] {
				if r.mentions(`"`+h+`"`) || items.mentions(`"`+h+`"`) {
					t.Errorf("level %d response names hidden %q:\n%s\n%s", level, h, r.raw, items.raw)
				}
			}
			for _, it := range items.js["items"].([]any) {
				m := it.(map[string]any)
				if p, ok := m["posterImageId"].(string); ok && p != m["id"] {
					t.Errorf("member %v artwork id %q is not its own", m["id"], p)
				}
			}
		})
	}
}

// When the ONLY artwork in a collection belongs to hidden titles, the tile has no poster
// (null), rather than borrowing a hidden title's.
// Mutation: same as above (remove the ceiling from collectionMembers).
func TestOC2211_CollectionWhoseOnlyArtworkIsHiddenHasNoPoster(t *testing.T) {
	// given: Animation: a G title with NO poster, an R title WITH a poster
	e := newColEnv(t)
	e.movie("A1", "Animation", sp("G"), 1)
	e.movie("A4", "Animation", sp("R"), 2)
	if _, err := e.db.Exec(`UPDATE items SET poster_path='/p.jpg' WHERE id='A4'`); err != nil {
		t.Fatal(err)
	}
	// when
	r := e.do(qaAlice, "GET", "/collections", "", e.kid)
	wantOK(t, r, 200)
	// then: the tile exists (A1 is visible), counts 1, and its poster is null
	var found bool
	for _, c := range r.js["collections"].([]any) {
		m := c.(map[string]any)
		if m["id"] == "animation" {
			found = true
			if m["posterImageId"] != nil || m["itemCount"] != float64(1) {
				t.Errorf("animation tile = %v, want posterImageId null and itemCount 1", m)
			}
		}
	}
	if !found {
		t.Errorf("no animation tile: %s", r.raw)
	}
	if r.mentions(`"A4"`) {
		t.Errorf("response names hidden A4: %s", r.raw)
	}
}
