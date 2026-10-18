package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"testing"

	"github.com/go-chi/chi/v5"
)

// TASK-924. The /tv/shows list grouped the VISIBLE rows (FR-250: the ceiling is in the WHERE,
// before grouping) while the detail routes expanded a show id through resolveShowFolders,
// which grouped EVERY row. A folder's resolved name is a majority vote over its episodes, so
// when a ceiling hides the majority the vote changes, and the two halves stopped agreeing:
// the kids' list said 3 episodes and the episode list showed fewer. The same header/list
// split as main.go's showGroupFolders comment, reached through the ceiling instead.
//
// Fixture: Daredevil/ holds 3 TV-MA "Marvel's Daredevil" episodes and 2 TV-PG "Daredevil:
// Born Again" ones; Born Again/ holds 1 more "Daredevil: Born Again". For a level-2 viewer
// only the 3 Born Again episodes are visible, and both folders resolve to that show.
func TestRestrictedShowDetailMatchesTheListedCount(t *testing.T) {
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	if _, err := db.Exec(showMergeSchema); err != nil {
		t.Fatalf("schema: %v", err)
	}
	ins := `INSERT INTO items(id, library_id, type, title, path, show_name, season_number,
	        episode_number, added_at, change_seq, content_rating) VALUES(?,?,?,?,?,?,?,?,?,?,?)`
	seed := []struct{ id, path, show, cert string }{
		{"dd1", "/Daredevil/S01E01.mkv", "Marvel's Daredevil", "TV-MA"},
		{"dd2", "/Daredevil/S01E02.mkv", "Marvel's Daredevil", "TV-MA"},
		{"dd3", "/Daredevil/S01E03.mkv", "Marvel's Daredevil", "TV-MA"},
		{"ba1", "/Daredevil/S01E04.mkv", "Daredevil: Born Again", "TV-PG"},
		{"ba2", "/Daredevil/S01E05.mkv", "Daredevil: Born Again", "TV-PG"},
		{"ba3", "/Born Again/S01E06.mkv", "Daredevil: Born Again", "TV-PG"},
	}
	for i, r := range seed {
		if _, err := db.Exec(ins, r.id, "lib_tv", "episode", "Episode", testTVRoot+r.path,
			r.show, 1, i+1, "2024-01-01T00:00:00Z", i+1, r.cert); err != nil {
			t.Fatalf("insert %s: %v", r.id, err)
		}
	}
	s := &Server{cfg: Config{TVPath: testTVRoot}, db: db}
	kid := viewer{UserID: "u1", ProfileID: "kid", MaxAgeLevel: 2}
	req := func(target string) *http.Request {
		r := httptest.NewRequest("GET", target, nil)
		ctx := context.WithValue(r.Context(), userKey, authedUser{ID: "u1", Username: "u1"})
		return r.WithContext(context.WithValue(ctx, viewerKey, kid))
	}

	rec := httptest.NewRecorder()
	s.handleTVShowsList(rec, req("/tv/shows"))
	var list struct{ Shows []listedShow }
	if err := json.Unmarshal(rec.Body.Bytes(), &list); err != nil {
		t.Fatalf("decode list: %v (%s)", err, rec.Body.String())
	}
	if len(list.Shows) != 1 || list.Shows[0].EpisodeCount != 3 {
		t.Fatalf("kids' list = %+v, want one show with 3 episodes", list.Shows)
	}
	listed := list.Shows[0]

	withShow := func(r *http.Request) *http.Request {
		rctx := chi.NewRouteContext()
		rctx.URLParams.Add("showId", listed.ID)
		return r.WithContext(context.WithValue(r.Context(), chi.RouteCtxKey, rctx))
	}

	rec = httptest.NewRecorder()
	s.handleTVShowEpisodes(rec, withShow(req("/tv/shows/"+url.PathEscape(listed.ID)+"/episodes")))
	if rec.Code != http.StatusOK {
		t.Fatalf("episodes status = %d (%s)", rec.Code, rec.Body.String())
	}
	var eps struct {
		Total int `json:"total"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &eps); err != nil {
		t.Fatalf("decode episodes: %v", err)
	}
	if eps.Total != listed.EpisodeCount {
		t.Errorf("episodes total %d, list episodeCount %d: the detail regrouped rows the viewer cannot see",
			eps.Total, listed.EpisodeCount)
	}

	rec = httptest.NewRecorder()
	s.handleTVShowSeasons(rec, withShow(req("/tv/shows/"+url.PathEscape(listed.ID)+"/seasons")))
	var seasons struct {
		Seasons []struct {
			EpisodeCount int `json:"episodeCount"`
		} `json:"seasons"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &seasons); err != nil {
		t.Fatalf("decode seasons: %v (%s)", err, rec.Body.String())
	}
	sum := 0
	for _, se := range seasons.Seasons {
		sum += se.EpisodeCount
	}
	if sum != listed.EpisodeCount {
		t.Errorf("seasons sum to %d, list episodeCount %d", sum, listed.EpisodeCount)
	}
}

// groupEpisodesByShow is the one assembly the five grouping sites share. Each case is a
// place where the copies differed or could have: what an empty/zero row means, season
// subfolders, unmatched episodes in a matched folder, which rows the majority is taken over
// (the ceiling and the rail window are the CALLER's row set), ties, and input order.
func TestGroupEpisodesByShow(t *testing.T) {
	n := func(s string) sql.NullString { return sql.NullString{String: s, Valid: s != ""} }
	type want struct{ folder, name, key string }
	cases := []struct {
		name string
		refs []episodeRef
		want []want
	}{
		{
			name: "part-matched folder: the unmatched episode files under the folder's name",
			refs: []episodeRef{
				{"/tv/Shameless/e1.mkv", n("Shameless")},
				{"/tv/Shameless/e2.mkv", n("Shameless")},
				{"/tv/Shameless/e3.mkv", n("")},
			},
			want: []want{
				{"Shameless", "Shameless", "shameless"},
				{"Shameless", "Shameless", "shameless"},
				{"Shameless", "Shameless", "shameless"},
			},
		},
		{
			name: "split folders carrying one show name share one key",
			refs: []episodeRef{
				{"/tv/Daredevil/S01E01.mkv", n("Daredevil")},
				{"/tv/Daredevil (2015)/S02E01.mkv", n("Daredevil")},
			},
			want: []want{
				{"Daredevil", "Daredevil", "daredevil"},
				{"Daredevil (2015)", "Daredevil", "daredevil"},
			},
		},
		{
			name: "unmatched folders key on the folder, case kept, and never merge",
			refs: []episodeRef{
				{"/tv/Unknown A/e1.mkv", n("")},
				{"/tv/Unknown B/e1.mkv", n("")},
			},
			want: []want{{"Unknown A", "", "Unknown A"}, {"Unknown B", "", "Unknown B"}},
		},
		{
			name: "season subfolder files under the show folder",
			refs: []episodeRef{{"/tv/The Bear/Season 2/S02E01.mkv", n("The Bear")}},
			want: []want{{"The Bear", "The Bear", "the bear"}},
		},
		{
			name: "root-level episode falls back to its filename stem",
			refs: []episodeRef{{"/tv/Pilot.mkv", n("")}},
			want: []want{{"Pilot", "", "Pilot"}},
		},
		{
			name: "zero ref (a film in a mixed rail) and an unplaceable path group nowhere",
			refs: []episodeRef{{}, {"/tv/.mkv", n("Ghost")}, {"/tv/Lost/e1.mkv", n("Lost")}},
			want: []want{{"", "", ""}, {"", "", ""}, {"Lost", "Lost", "lost"}},
		},
		{
			name: "majority wins over a stray mismatch",
			refs: []episodeRef{
				{"/tv/NCIS/e1.mkv", n("NCIS")},
				{"/tv/NCIS/e2.mkv", n("NCIS: Sydney")},
				{"/tv/NCIS/e3.mkv", n("NCIS")},
			},
			want: []want{{"NCIS", "NCIS", "ncis"}, {"NCIS", "NCIS", "ncis"}, {"NCIS", "NCIS", "ncis"}},
		},
		{
			name: "a tie resolves on the name, never on input order",
			refs: []episodeRef{
				{"/tv/Mix/e1.mkv", n("Zeta")},
				{"/tv/Mix/e2.mkv", n("Alpha")},
			},
			want: []want{{"Mix", "Alpha", "alpha"}, {"Mix", "Alpha", "alpha"}},
		},
		{
			// The ceiling case: the caller's WHERE removed the TV-MA majority, so the vote is
			// taken over what remains and this folder joins the other Born Again folder.
			name: "the majority is taken over the rows passed in (ceiling applied before)",
			refs: []episodeRef{
				{"/tv/Daredevil/S01E04.mkv", n("Daredevil: Born Again")},
				{"/tv/Born Again/S01E01.mkv", n("Daredevil: Born Again")},
			},
			want: []want{
				{"Daredevil", "Daredevil: Born Again", "daredevil: born again"},
				{"Born Again", "Daredevil: Born Again", "daredevil: born again"},
			},
		},
		{
			name: "the same folder with its majority present votes the other way",
			refs: []episodeRef{
				{"/tv/Daredevil/S01E01.mkv", n("Marvel's Daredevil")},
				{"/tv/Daredevil/S01E02.mkv", n("Marvel's Daredevil")},
				{"/tv/Daredevil/S01E04.mkv", n("Daredevil: Born Again")},
			},
			want: []want{
				{"Daredevil", "Marvel's Daredevil", "marvel's daredevil"},
				{"Daredevil", "Marvel's Daredevil", "marvel's daredevil"},
				{"Daredevil", "Marvel's Daredevil", "marvel's daredevil"},
			},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			check := func(refs []episodeRef, want []want) {
				t.Helper()
				got := groupEpisodesByShow(refs, "/tv/")
				if len(got) != len(want) {
					t.Fatalf("got %d groups for %d refs", len(got), len(want))
				}
				for i, w := range want {
					g := got[i]
					if g.Folder != w.folder || g.ShowName.String != w.name ||
						g.ShowName.Valid != (w.name != "") || g.Key != w.key {
						t.Errorf("ref %d (%q) = {%q %q valid=%v %q}, want {%q %q %q}", i, refs[i].Path,
							g.Folder, g.ShowName.String, g.ShowName.Valid, g.Key, w.folder, w.name, w.key)
					}
				}
			}
			check(tc.refs, tc.want)
			// Order-independent: the five sites read rows in five different orders.
			rr, rw := make([]episodeRef, len(tc.refs)), make([]want, len(tc.want))
			for i := range tc.refs {
				rr[len(rr)-1-i], rw[len(rw)-1-i] = tc.refs[i], tc.want[i]
			}
			check(rr, rw)
		})
	}
}
