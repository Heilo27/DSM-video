package main

// TASK-916 contract: ProfilesAPI.md "Item fields" says every item payload carries
// contentRating (the stored certification, null when unrated) and ageLevel (1-4, unrated 4).
// handleItems and friends omitted both. The expectations below come from that document:
// G is level 1, an unrated title is null and level 4.

import (
	"net/http"
	"testing"
)

// ratedFixture is one title the route must carry, with the wire pair it must show.
type ratedFixture struct {
	id        string
	wantCert  any // string, or nil for JSON null
	wantLevel float64
}

var (
	fxRatedMovie   = ratedFixture{enfMovG, "G", 1}
	fxUnratedMovie = ratedFixture{enfMovUn, nil, 4}
	fxRatedEp      = ratedFixture{"FxEpG1", "TV-G", 1}
	fxUnratedEp    = ratedFixture{"FxEpUn1", nil, 4}
)

// collectItems walks a decoded response for every JSON object whose "id" is a string,
// keyed by id. It descends into arrays and objects so one walker serves flat lists,
// {"seasons":[{"episodes":[...]}]} and a bare detail object alike.
func collectItems(node any, out map[string]map[string]any) {
	switch n := node.(type) {
	case map[string]any:
		if id, ok := n["id"].(string); ok {
			out[id] = n
		}
		for _, child := range n {
			collectItems(child, out)
		}
	case []any:
		for _, child := range n {
			collectItems(child, out)
		}
	}
}

func assertRatingPair(t *testing.T, items map[string]map[string]any, id string, wantCert any, wantLevel float64) {
	t.Helper()
	it, ok := items[id]
	if !ok {
		t.Fatalf("item %q is absent from the payload", id)
	}
	cert, hasCert := it["contentRating"]
	if !hasCert {
		t.Errorf("%s: contentRating key is missing", id)
	} else if cert != wantCert {
		t.Errorf("%s: contentRating = %#v, want %#v", id, cert, wantCert)
	}
	lvl, hasLvl := it["ageLevel"]
	if !hasLvl {
		t.Errorf("%s: ageLevel key is missing", id)
	} else if lvl != wantLevel {
		t.Errorf("%s: ageLevel = %#v, want %v", id, lvl, wantLevel)
	}
}

func TestFR240_EveryItemRouteCarriesContentRatingAndAgeLevel(t *testing.T) {
	// given: rated and unrated movies and episodes, a watchlist, downloads and a playlist
	w := newEnfWorld(t)
	adult := enfViewers[2]

	routes := []struct {
		name  string
		path  string
		items []ratedFixture
	}{
		{"items_movies", "/items?libraryId=lib_movies", []ratedFixture{fxRatedMovie, fxUnratedMovie}},
		{"items_episodes", "/items?libraryId=lib_tv", []ratedFixture{fxRatedEp, fxUnratedEp}},
		{"items_justWatched", "/items?libraryId=lib_movies&filter=justWatched", []ratedFixture{fxRatedMovie, fxUnratedMovie}},
		{"search", "/search?q=Fx", []ratedFixture{fxRatedMovie, fxUnratedMovie, fxRatedEp, fxUnratedEp}},
		{"item_detail_rated", "/items/" + enfMovG, []ratedFixture{fxRatedMovie}},
		{"item_detail_unrated", "/items/" + enfMovUn, []ratedFixture{fxUnratedMovie}},
		{"watchlist", "/watchlist", []ratedFixture{fxRatedMovie, fxUnratedMovie}},
		{"downloads", "/downloads", []ratedFixture{fxRatedMovie, fxUnratedMovie}},
		{"playlist_detail", "/playlists/" + w.playlistID, []ratedFixture{fxRatedMovie, fxUnratedMovie}},
		{"tv_show_episodes_rated", "/tv/shows/" + enfShowG + "/episodes", []ratedFixture{fxRatedEp}},
		{"tv_show_episodes_unrated", "/tv/shows/" + enfShowUn + "/episodes", []ratedFixture{fxUnratedEp}},
		{"show_detail_episodes_rated", "/shows/" + enfShowG, []ratedFixture{fxRatedEp}},
		{"show_detail_episodes_unrated", "/shows/" + enfShowUn, []ratedFixture{fxUnratedEp}},
		// A show carries its representative episode's rating, keyed by its folder id.
		{"shows_list", "/shows", []ratedFixture{{enfShowG, "TV-G", 1}, {enfShowUn, nil, 4}}},
		{"tv_shows_list", "/tv/shows", []ratedFixture{{enfShowG, "TV-G", 1}, {enfShowUn, nil, 4}}},
		{"show_detail_show_rated", "/shows/" + enfShowG, []ratedFixture{{enfShowG, "TV-G", 1}}},
		{"show_detail_show_unrated", "/shows/" + enfShowUn, []ratedFixture{{enfShowUn, nil, 4}}},
		{"just_added", "/just-added", []ratedFixture{fxRatedMovie, fxUnratedMovie}},
	}
	for _, rt := range routes {
		t.Run(rt.name, func(t *testing.T) {
			// when: an unrestricted viewer reads the route
			r := w.get(adult, rt.path)
			if r.code != http.StatusOK {
				t.Fatalf("GET %s = %d %s", rt.path, r.code, r.raw)
			}
			found := map[string]map[string]any{}
			collectItems(r.js, found)
			// then: each fixture shows its stored certification (or null) and its level
			for _, fx := range rt.items {
				assertRatingPair(t, found, fx.id, fx.wantCert, fx.wantLevel)
			}
		})
	}
}

// A restricted viewer gets the same pair on what it may see; the fields describe the title,
// never the viewer.
func TestFR241_AgeLevelDoesNotDependOnTheViewer(t *testing.T) {
	w := newEnfWorld(t)
	for _, path := range []string{"/items?libraryId=lib_movies", "/search?q=Fx", "/watchlist", "/downloads"} {
		r := w.get(enfViewers[0], path) // kid
		if r.code != http.StatusOK {
			t.Fatalf("GET %s = %d %s", path, r.code, r.raw)
		}
		found := map[string]map[string]any{}
		collectItems(r.js, found)
		assertRatingPair(t, found, enfMovG, "G", 1)
	}
}
