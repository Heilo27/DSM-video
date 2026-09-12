package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/go-chi/chi/v5"
	_ "modernc.org/sqlite"
)

// Commit ba1160c merged the GROUPING but not the IDENTITY.
//
// handleTVShowsList keyed showMap by showGroupKey — the merged key — and aggregated count and
// seasons across every folder in the group, which was right. But the emitted "id" stayed
// info.folderName, whichever folder happened to be scanned FIRST, and showLastWatched was
// keyed by the BARE folder name. Two user-visible consequences:
//
//  1. The detail request made with that id resolved exactly ONE folder, so the header said
//     "24 episodes" and the episode list showed 12.
//  2. Watching an episode in the group's SECOND folder never updated the merged show's
//     lastWatchedAt, so a show watched last night sorted to the bottom of Recently Watched.
//
// Identity and lastWatched now use the same merged key as the grouping, and the detail path
// expands a folder id back into every folder in the group via resolveShowFolders.

const showMergeSchema = `
CREATE TABLE items(
  id TEXT PRIMARY KEY, library_id TEXT, type TEXT, title TEXT, episode_title TEXT,
  year INT, path TEXT, duration_seconds INT, added_at TEXT, updated_at TEXT,
  rating REAL, poster_path TEXT, backdrop_path TEXT, overview TEXT, genres TEXT,
  director TEXT, show_name TEXT, season_number INT, episode_number INT,
  change_seq INT, show_folder_id TEXT, tmdb_id INT);
CREATE TABLE progress(
  item_id TEXT, user_id TEXT, position_seconds INT, duration_seconds INT,
  updated_at TEXT, write_seq INT, PRIMARY KEY(item_id, user_id));
`

const testTVRoot = "/tv"

// A show split across two folders: "Daredevil" (S1, 2 episodes) and "Daredevil (2015)"
// (S2, 1 episode). Both carry the same TMDb show_name, which is what makes them one show.
// Merged truth: ONE show, 3 episodes, 2 seasons.
func newShowMergeServer(t *testing.T) *Server {
	t.Helper()
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	if _, err := db.Exec(showMergeSchema); err != nil {
		t.Fatalf("schema: %v", err)
	}

	ins := `INSERT INTO items(id, library_id, type, title, path, show_name, season_number,
	        episode_number, added_at, change_seq) VALUES(?,?,?,?,?,?,?,?,?,?)`
	rows := []struct {
		id, path string
		season   int
		episode  int
		added    string
		seq      int
	}{
		{"ep_a1", testTVRoot + "/Daredevil/S01E01.mkv", 1, 1, "2024-01-01T00:00:00Z", 10},
		{"ep_a2", testTVRoot + "/Daredevil/S01E02.mkv", 1, 2, "2024-01-02T00:00:00Z", 11},
		{"ep_b1", testTVRoot + "/Daredevil (2015)/S02E01.mkv", 2, 1, "2024-02-01T00:00:00Z", 12},
	}
	for _, r := range rows {
		if _, err := db.Exec(ins, r.id, "lib_tv", "episode", "Episode", r.path,
			"Daredevil", r.season, r.episode, r.added, r.seq); err != nil {
			t.Fatalf("insert %s: %v", r.id, err)
		}
	}
	return &Server{cfg: Config{TVPath: testTVRoot}, db: db}
}

func authedReq(method, target, userID string) *http.Request {
	req := httptest.NewRequest(method, target, nil)
	return req.WithContext(context.WithValue(req.Context(), userKey,
		authedUser{ID: userID, Username: userID}))
}

type listedShow struct {
	ID            string  `json:"id"`
	Title         string  `json:"title"`
	SeasonCount   int     `json:"seasonCount"`
	EpisodeCount  int     `json:"episodeCount"`
	LastWatchedAt *string `json:"lastWatchedAt"`
}

func listShows(t *testing.T, s *Server, userID string) []listedShow {
	t.Helper()
	rec := httptest.NewRecorder()
	s.handleTVShowsList(rec, authedReq("GET", "/tv/shows", userID))
	if rec.Code != http.StatusOK {
		t.Fatalf("list status = %d, want 200", rec.Code)
	}
	var body struct{ Shows []listedShow }
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode list: %v (%s)", err, rec.Body.String())
	}
	return body.Shows
}

// The merged list: ONE show, the counts summed across BOTH folders.
func TestSplitShowListsOnceWithMergedCounts(t *testing.T) {
	s := newShowMergeServer(t)
	shows := listShows(t, s, "")

	if len(shows) != 1 {
		t.Fatalf("shows = %d, want 1 (the two folders are one show)", len(shows))
	}
	got := shows[0]
	if got.EpisodeCount != 3 {
		t.Errorf("episodeCount = %d, want 3", got.EpisodeCount)
	}
	if got.SeasonCount != 2 {
		t.Errorf("seasonCount = %d, want 2", got.SeasonCount)
	}
	if got.Title != "Daredevil" {
		t.Errorf("title = %q, want %q", got.Title, "Daredevil")
	}
	// The id must be a FOLDER name — see the comment on the emitted id in handleTVShowsList.
	// Persisted ids (watchlist, Top Shelf, dsvideo://item/{id}) are folder names, so the id
	// must stay in that namespace; it is the lowercased group key that must NOT leak out.
	if got.ID != "Daredevil" && got.ID != "Daredevil (2015)" {
		t.Errorf("id = %q, want one of the group's folder names", got.ID)
	}
	if got.ID == "daredevil" {
		t.Error("id leaked the lowercased group key — that invalidates every persisted id")
	}
}

// THE DEFECT. The header said 24 and the list showed 12: the detail request resolved the one
// folder named by the id instead of the group the list counted. Whichever folder the list
// emits, the detail must agree with the count the list reported.
func TestShowDetailMatchesTheMergedCount(t *testing.T) {
	s := newShowMergeServer(t)
	listed := listShows(t, s, "")[0]

	// Episodes: must be all 3, not the 2 (or 1) in the single named folder.
	rec := httptest.NewRecorder()
	req := authedReq("GET", "/tv/shows/"+listed.ID+"/episodes", "")
	rctx := chi.NewRouteContext()
	rctx.URLParams.Add("showId", listed.ID)
	s.handleTVShowEpisodes(rec, req.WithContext(
		context.WithValue(req.Context(), chi.RouteCtxKey, rctx)))
	if rec.Code != http.StatusOK {
		t.Fatalf("episodes status = %d", rec.Code)
	}
	var eps struct {
		Total int              `json:"total"`
		Items []map[string]any `json:"items"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &eps); err != nil {
		t.Fatalf("decode episodes: %v", err)
	}
	if eps.Total != 3 {
		t.Errorf("episodes total = %d, want 3 (must equal the list's episodeCount)", eps.Total)
	}
	if len(eps.Items) != 3 {
		t.Errorf("episodes returned = %d, want 3", len(eps.Items))
	}
	if eps.Total != listed.EpisodeCount {
		t.Errorf("detail total %d disagrees with list episodeCount %d — the header/list split",
			eps.Total, listed.EpisodeCount)
	}

	// Seasons: must be both seasons, one per folder.
	rec = httptest.NewRecorder()
	req = authedReq("GET", "/tv/shows/"+listed.ID+"/seasons", "")
	rctx = chi.NewRouteContext()
	rctx.URLParams.Add("showId", listed.ID)
	s.handleTVShowSeasons(rec, req.WithContext(
		context.WithValue(req.Context(), chi.RouteCtxKey, rctx)))
	var seasonsBody struct {
		Seasons []struct {
			SeasonNumber int `json:"seasonNumber"`
			EpisodeCount int `json:"episodeCount"`
		} `json:"seasons"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &seasonsBody); err != nil {
		t.Fatalf("decode seasons: %v", err)
	}
	if len(seasonsBody.Seasons) != 2 {
		t.Fatalf("seasons = %d, want 2", len(seasonsBody.Seasons))
	}
	if seasonsBody.Seasons[0].SeasonNumber != 1 || seasonsBody.Seasons[0].EpisodeCount != 2 {
		t.Errorf("season 1 = %+v, want {1 2}", seasonsBody.Seasons[0])
	}
	if seasonsBody.Seasons[1].SeasonNumber != 2 || seasonsBody.Seasons[1].EpisodeCount != 1 {
		t.Errorf("season 2 = %+v, want {2 1}", seasonsBody.Seasons[1])
	}
}

// THE SECOND DEFECT. showLastWatched was keyed by the bare folder name while the show was
// keyed by showGroupKey, so progress in the group's other folder never reached the show.
// Watching the SECOND folder's episode must set the merged show's lastWatchedAt.
func TestLastWatchedReflectsEitherFolder(t *testing.T) {
	s := newShowMergeServer(t)

	// Watch an episode in the SECOND folder only — the one the old code could not see.
	if _, err := s.db.Exec(
		`INSERT INTO progress(item_id, user_id, position_seconds, duration_seconds, updated_at, write_seq)
		 VALUES(?,?,?,?,?,?)`,
		"ep_b1", "u1", 600, 1800, "2024-06-01T12:00:00Z", 1); err != nil {
		t.Fatalf("progress insert: %v", err)
	}

	shows := listShows(t, s, "u1")
	if len(shows) != 1 {
		t.Fatalf("shows = %d, want 1", len(shows))
	}
	if shows[0].LastWatchedAt == nil {
		t.Fatal("lastWatchedAt is nil — progress in the group's second folder was dropped")
	}
	if *shows[0].LastWatchedAt != "2024-06-01T12:00:00Z" {
		t.Errorf("lastWatchedAt = %q, want %q", *shows[0].LastWatchedAt, "2024-06-01T12:00:00Z")
	}
}

// The MOST RECENT watch in either folder wins, not whichever folder sorts first.
func TestLastWatchedTakesTheMostRecentAcrossFolders(t *testing.T) {
	s := newShowMergeServer(t)
	ins := `INSERT INTO progress(item_id, user_id, position_seconds, duration_seconds, updated_at, write_seq)
	        VALUES(?,?,?,?,?,?)`
	// First folder watched in January, second folder watched in June.
	if _, err := s.db.Exec(ins, "ep_a1", "u1", 300, 1800, "2024-01-15T08:00:00Z", 1); err != nil {
		t.Fatalf("progress a1: %v", err)
	}
	if _, err := s.db.Exec(ins, "ep_b1", "u1", 900, 1800, "2024-06-20T22:30:00Z", 2); err != nil {
		t.Fatalf("progress b1: %v", err)
	}

	shows := listShows(t, s, "u1")
	if shows[0].LastWatchedAt == nil {
		t.Fatal("lastWatchedAt is nil")
	}
	if *shows[0].LastWatchedAt != "2024-06-20T22:30:00Z" {
		t.Errorf("lastWatchedAt = %q, want the June watch %q",
			*shows[0].LastWatchedAt, "2024-06-20T22:30:00Z")
	}
}

// resolveShowFolders must expand EITHER folder id to the whole group, and must leave a
// single-folder show alone — that is the case that must not churn.
func TestResolveShowFolders(t *testing.T) {
	s := newShowMergeServer(t)
	tvRoot := testTVRoot + "/"

	for _, id := range []string{"Daredevil", "Daredevil (2015)"} {
		got := s.resolveShowFolders(id, tvRoot)
		if len(got) != 2 {
			t.Errorf("resolveShowFolders(%q) = %v, want both folders", id, got)
		}
	}

	// A show in one folder with no sibling resolves to exactly itself.
	if _, err := s.db.Exec(
		`INSERT INTO items(id, library_id, type, title, path, show_name, season_number, episode_number, added_at, change_seq)
		 VALUES(?,?,?,?,?,?,?,?,?,?)`,
		"ep_c1", "lib_tv", "episode", "Episode", testTVRoot+"/The Bear/S01E01.mkv",
		"The Bear", 1, 1, "2024-03-01T00:00:00Z", 20); err != nil {
		t.Fatalf("insert: %v", err)
	}
	got := s.resolveShowFolders("The Bear", tvRoot)
	if len(got) != 1 || got[0] != "The Bear" {
		t.Errorf("single-folder show resolved to %v, want [The Bear]", got)
	}

	// An id with no matching folder falls back to itself rather than returning nothing,
	// so the show_name fallback downstream still gets its chance to fire.
	got = s.resolveShowFolders("Nonexistent", tvRoot)
	if len(got) != 1 || got[0] != "Nonexistent" {
		t.Errorf("unknown id resolved to %v, want [Nonexistent]", got)
	}
}

// The pure grouping rule, without a database.
func TestShowGroupFoldersMapsEveryFolderToItsGroup(t *testing.T) {
	paths := []string{
		"/tv/Daredevil/S01E01.mkv",
		"/tv/Daredevil (2015)/S02E01.mkv",
		"/tv/The Bear/S01E01.mkv",
	}
	names := []sql.NullString{
		{String: "Daredevil", Valid: true},
		{String: "Daredevil", Valid: true},
		{String: "The Bear", Valid: true},
	}
	got := showGroupFolders(paths, names, "/tv/")

	if len(got["Daredevil"]) != 2 || len(got["Daredevil (2015)"]) != 2 {
		t.Errorf("split show did not map both folders: %v", got)
	}
	if len(got["The Bear"]) != 1 {
		t.Errorf("unsplit show = %v, want one folder", got["The Bear"])
	}
	// Unmatched content (no show_name) stays folder-scoped: two unmatched folders are two shows.
	got = showGroupFolders(
		[]string{"/tv/Unknown A/e1.mkv", "/tv/Unknown B/e1.mkv"},
		[]sql.NullString{{}, {}}, "/tv/")
	if len(got["Unknown A"]) != 1 || len(got["Unknown B"]) != 1 {
		t.Errorf("unmatched folders must not merge: %v", got)
	}
}

// The show_name fallback in handleTVShowEpisodes is gated on matchCount == 0. It was reported
// as dead. It is NOT dead: a showID that is a TMDb display name rather than a folder matches
// no path, so the count is 0 and the fallback fires. This pins that behaviour so the gate is
// not "simplified" away.
func TestShowNameFallbackStillFires(t *testing.T) {
	s := newShowMergeServer(t)

	// "Daredevil" IS a folder here, so use a show whose folder name differs from show_name.
	if _, err := s.db.Exec(
		`INSERT INTO items(id, library_id, type, title, path, show_name, season_number, episode_number, added_at, change_seq)
		 VALUES(?,?,?,?,?,?,?,?,?,?)`,
		"ep_d1", "lib_tv", "episode", "Episode", testTVRoot+"/Bear.2022.1080p/S01E01.mkv",
		"The Bear", 1, 1, "2024-04-01T00:00:00Z", 30); err != nil {
		t.Fatalf("insert: %v", err)
	}

	// Request by the TMDb display name, which matches NO folder on disk.
	rec := httptest.NewRecorder()
	req := authedReq("GET", "/tv/shows/The%20Bear/episodes", "")
	rctx := chi.NewRouteContext()
	rctx.URLParams.Add("showId", "The Bear")
	s.handleTVShowEpisodes(rec, req.WithContext(
		context.WithValue(req.Context(), chi.RouteCtxKey, rctx)))

	var eps struct {
		Total int `json:"total"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &eps); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if eps.Total != 1 {
		t.Errorf("show_name fallback total = %d, want 1 — the fallback did not fire", eps.Total)
	}
}
