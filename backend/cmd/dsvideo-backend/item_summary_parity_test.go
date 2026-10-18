package main

// TASK-1058 (Rule 9): every title-list endpoint builds its elements through itemSummary, so
// for the same item its element has the SAME KEY SET as the /items element, apart from the
// extras and omissions the table below names. A key added to itemSummary reaches all of them;
// an endpoint that hand-builds its own shape again fails here.

import (
	"fmt"
	"net/http"
	"sort"
	"testing"
)

const (
	parMovie     = "parity_movie"  // has progress, watchlist, download, playlist entry
	parEpisode   = "parity_ep"     // same, an episode of parShow
	parFreeMovie = "parity_fmovie" // no progress: what /suggested may offer
	parFreeEp    = "parity_fep"
	parShow      = "ParityShow"
	parFreeShow  = "ParityFreeShow"
)

// parityEnv seeds two movies and two episodes with EVERY optional summary column set (year,
// rating, duration, artwork, season/episode, show folder), so a key an endpoint forgets
// shows up as a difference rather than hiding behind an absent column.
func parityEnv(t *testing.T) (*colEnv, string, string) {
	t.Helper()
	e := newColEnv(t)
	pg := "PG"
	e.movie(parMovie, "Animation", &pg, 1)
	e.episode(parEpisode, parShow, "Animation", &pg, 2)
	e.movie(parFreeMovie, "Animation", &pg, 3)
	e.episode(parFreeEp, parFreeShow, "Animation", &pg, 4)
	for _, id := range []string{parMovie, parEpisode, parFreeMovie, parFreeEp} {
		if _, err := e.db.Exec(`UPDATE items SET year = 2001, rating = 7.5, duration_seconds = 5400,
			poster_path = '/p', backdrop_path = '/b' WHERE id = ?`, id); err != nil {
			t.Fatalf("decorate %s: %v", id, err)
		}
	}
	for id, show := range map[string]string{parEpisode: parShow, parFreeEp: parFreeShow} {
		if _, err := e.db.Exec(`UPDATE items SET season_number = 1, episode_number = 2, show_folder_id = ? WHERE id = ?`,
			show, id); err != nil {
			t.Fatalf("decorate episode %s: %v", id, err)
		}
	}

	profile := e.kid
	for _, id := range []string{parMovie, parEpisode} {
		r := e.do(qaAlice, "POST", "/items/"+id+"/progress", `{"positionSeconds":60,"durationSeconds":5400}`, profile)
		wantOK(t, r, 200)
		wantOK(t, e.do(qaAlice, "POST", "/watchlist/"+id, "", profile), 200)
		wantOK(t, e.do(qaAlice, "POST", "/downloads/"+id, "", profile), 200)
	}
	pl := e.do(qaAlice, "POST", "/playlists", `{"title":"Parity"}`, profile)
	wantOK(t, pl, 201)
	for _, id := range []string{parMovie, parEpisode} {
		wantOK(t, e.do(qaAlice, "POST", "/playlists/"+pl.str("id")+"/items", jb(map[string]any{"itemId": id}), profile), 200)
	}
	return e, profile, pl.str("id")
}

func keysOf(m map[string]any) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func TestTASK1058_EveryTitleListElementHasTheItemSummaryKeys(t *testing.T) {
	e, profile, playlistID := parityEnv(t)

	// The reference: the /items element of each item, as the viewing profile sees it.
	ref := map[string]map[string]any{}
	for _, lib := range []string{"lib_movies", "lib_tv"} {
		r := e.do(qaAlice, "GET", "/items?libraryId="+lib, "", profile)
		wantOK(t, r, 200)
		collectItems(r.js, ref)
	}
	for _, id := range []string{parMovie, parEpisode, parFreeMovie, parFreeEp} {
		if ref[id] == nil {
			t.Fatalf("/items did not list %s", id)
		}
	}
	// Sanity: the fixture really is fully populated, so the comparison has teeth.
	for _, k := range []string{"id", "type", "title", "year", "durationSeconds", "addedAt", "rating",
		"posterImageId", "backdropImageId", "contentRating", "ageLevel"} {
		if _, ok := ref[parMovie][k]; !ok {
			t.Fatalf("reference movie lacks %q: %v", k, keysOf(ref[parMovie]))
		}
	}
	for _, k := range []string{"showName", "seasonNumber", "episodeNumber", "showFolderId", "progress"} {
		if _, ok := ref[parEpisode][k]; !ok {
			t.Fatalf("reference episode lacks %q: %v", k, keysOf(ref[parEpisode]))
		}
	}

	both := []string{parMovie, parEpisode}
	free := []string{parFreeMovie, parFreeEp}
	// extra: keys the endpoint adds on top of the summary. omit: summary keys it leaves off.
	// Every entry is a documented difference (docs/api/DSVideoBackendAPI.md).
	table := []struct {
		name  string
		path  string
		ids   []string
		extra []string
		omit  []string
	}{
		{"items_justWatched_movies", "/items?libraryId=lib_movies&filter=justWatched", []string{parMovie}, nil, nil},
		{"items_justWatched_tv", "/items?libraryId=lib_tv&filter=justWatched", []string{parEpisode}, nil, nil},
		{"search", "/search?q=parity", both, nil, nil},
		{"playlist", "/playlists/" + playlistID, both, nil, nil},
		{"downloads", "/downloads", both, nil, nil},
		{"watchlist", "/watchlist", both, []string{"libraryId"}, nil},
		{"tv_show_episodes", "/tv/shows/" + parShow + "/episodes", []string{parEpisode}, nil, nil},
		{"similar", "/items/" + parMovie + "/similar", []string{parFreeMovie}, nil, nil},
		// Shared by every profile (cached), so no progress (FR-230).
		{"just_added", "/just-added", both, []string{"libraryId"}, []string{"progress"}},
		// Excludes every title the profile has progress on, so none of its titles has any.
		{"suggested", "/suggested", free, nil, nil},
		// A show is represented by one of its episodes, whose progress would misdescribe it.
		{"collection_items", "/collections/animation/items", both, []string{"libraryId"}, []string{"progress"}},
	}
	for _, tc := range table {
		t.Run(tc.name, func(t *testing.T) {
			r := e.do(qaAlice, "GET", tc.path, "", profile)
			wantOK(t, r, http.StatusOK)
			got := map[string]map[string]any{}
			collectItems(r.js, got)
			for _, id := range tc.ids {
				el := got[id]
				if el == nil {
					t.Fatalf("GET %s did not list %s: %s", tc.path, id, r.raw)
				}
				want := map[string]bool{}
				for k := range ref[id] {
					want[k] = true
				}
				for _, k := range tc.extra {
					want[k] = true
				}
				for _, k := range tc.omit {
					delete(want, k)
				}
				for k := range want {
					if _, ok := el[k]; !ok {
						t.Errorf("%s: %s lacks %q (has %v)", tc.path, id, k, keysOf(el))
					}
				}
				for k := range el {
					if !want[k] {
						t.Errorf("%s: %s carries unexpected %q (want %v)", tc.path, id, k, fmt.Sprint(sortedSet(want)))
					}
				}
			}
		})
	}
}

func sortedSet(s map[string]bool) []string {
	out := make([]string, 0, len(s))
	for k := range s {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
