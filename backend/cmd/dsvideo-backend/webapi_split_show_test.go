package main

// TASK-995 — the DS Video web plane lists a show split across two folders ONCE, so its
// episode list must return the episodes of BOTH folders, whichever folder the list happened
// to file the show under (that depends on database row order).

import (
	"encoding/json"
	"net/url"
	"strconv"
	"testing"
)

// seedSplitShow files "Daredevil" across two folders (both carry the same TMDb show_name,
// which is what makes them one show) plus an unrelated show, inserting the two folders in
// the requested order.
func seedSplitShow(e *qaEnv, firstFolderFirst bool) {
	at := "2026-01-01T00:00:00Z"
	a := func() {
		e.pcTitle("dd_s1e1", "lib_tv", "episode", "/tv/Daredevil/S01E01.mkv", "Daredevil", "Drama", at, nil)
		e.pcTitle("dd_s1e2", "lib_tv", "episode", "/tv/Daredevil/S01E02.mkv", "Daredevil", "Drama", at, nil)
	}
	b := func() {
		e.pcTitle("dd_s2e1", "lib_tv", "episode", "/tv/Daredevil (2015)/S02E01.mkv", "Daredevil", "Drama", at, nil)
	}
	if firstFolderFirst {
		a()
		b()
	} else {
		b()
		a()
	}
	e.pcTitle("other_e1", "lib_tv", "episode", "/tv/Other/S01E01.mkv", "Other", "Drama", at, nil)
}

func TestWebAPITVShowEpisodeList_SplitShowReturnsEveryFolder(t *testing.T) {
	for _, tc := range []struct {
		name             string
		firstFolderFirst bool
	}{
		{"Daredevil folder inserted first", true},
		{"Daredevil (2015) folder inserted first", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newQAEnv(t)
			e.s.cfg.TVPath = "/tv"
			seedSplitShow(e, tc.firstFolderFirst)
			sid := pcSession(t, qaAlice)

			// The real flow: list the shows (which stores the id mapping), then open one.
			list := pcCall(t, e.s.handleWebAPITVShow, "list", url.Values{"_sid": {sid}})
			titles, total := list.listTitles(t, "tvshow")
			if !sameStrings(titles, []string{"Daredevil", "Other"}) || total != 2 {
				t.Fatalf("show list = %v (total %d), want [Daredevil Other] (total 2)", titles, total)
			}
			var shows []struct {
				ID    int    `json:"id"`
				Title string `json:"title"`
			}
			if err := json.Unmarshal(list.Data["tvshow"], &shows); err != nil {
				t.Fatal(err)
			}
			id := ""
			for _, s := range shows {
				if s.Title == "Daredevil" {
					id = strconv.Itoa(s.ID)
				}
			}
			if id == "" {
				t.Fatalf("Daredevil missing from %s", list.Data["tvshow"])
			}

			eps, total := pcCall(t, e.s.handleWebAPITVShowEpisode, "list",
				url.Values{"_sid": {sid}, "tvshow_id": {id}}).listTitles(t, "tvshow_episode")
			want := []string{"dd_s1e1", "dd_s1e2", "dd_s2e1"}
			if !sameStrings(eps, want) {
				t.Errorf("episodes = %v, want %v (every folder of the show)", eps, want)
			}
			if total != 3 {
				t.Errorf("total = %d, want 3 (the count must describe the rows)", total)
			}

			// getinfo reads the same folders: its metadata is aggregated over the whole show.
			if r := pcCall(t, e.s.handleWebAPITVShow, "getinfo", url.Values{"_sid": {sid}, "id": {id}}); !r.Success {
				t.Errorf("getinfo failed: code %d", r.Error.Code)
			}
		})
	}
}

// A show confined to one folder is unaffected by the group expansion.
func TestWebAPITVShowEpisodeList_SingleFolderShowUnchanged(t *testing.T) {
	e := newQAEnv(t)
	e.s.cfg.TVPath = "/tv"
	seedSplitShow(e, true)
	sid := pcSession(t, qaAlice)
	pcMap(sid, func(m *idMapping) { m.tvShows["77"] = "Other" })
	eps, total := pcCall(t, e.s.handleWebAPITVShowEpisode, "list",
		url.Values{"_sid": {sid}, "tvshow_id": {"77"}}).listTitles(t, "tvshow_episode")
	if !sameStrings(eps, []string{"other_e1"}) || total != 1 {
		t.Errorf("Other episodes = %v (total %d), want [other_e1] (total 1)", eps, total)
	}
}

// The kid profile's ceiling hides part of a split show: the episode list and getinfo
// honour it exactly as the list did (FR-250/FR-251), and a fully hidden show is refused.
func TestWebAPITVShowEpisodeList_SplitShowHoldsToTheCeiling(t *testing.T) {
	e := newQAEnv(t)
	e.pcFamily()
	e.s.cfg.TVPath = "/tv"
	at := "2026-01-01T00:00:00Z"
	e.pcTitle("k_a", "lib_tv", "episode", "/tv/Kids/e1.mkv", "Kids", "Animation", at, sp("TV-Y"))
	e.pcTitle("k_b", "lib_tv", "episode", "/tv/Kids (2020)/e2.mkv", "Kids", "Animation", at, sp("TV-Y"))
	e.pcTitle("m_a", "lib_tv", "episode", "/tv/Mature/e1.mkv", "Mature", "Drama", at, sp("TV-MA"))
	e.pcTitle("m_b", "lib_tv", "episode", "/tv/Mature (2020)/e2.mkv", "Mature", "Drama", at, sp("TV-MA"))
	sid := pcSession(t, qaAlice)
	pcMap(sid, func(m *idMapping) {
		m.tvShows["1"] = "Kids (2020)"
		m.tvShows["2"] = "Mature (2020)"
	})

	eps, total := pcCall(t, e.s.handleWebAPITVShowEpisode, "list",
		url.Values{"_sid": {sid}, "tvshow_id": {"1"}}).listTitles(t, "tvshow_episode")
	if !sameStrings(eps, []string{"k_a", "k_b"}) || total != 2 {
		t.Errorf("Kids episodes = %v (total %d), want [k_a k_b] (total 2)", eps, total)
	}
	eps, total = pcCall(t, e.s.handleWebAPITVShowEpisode, "list",
		url.Values{"_sid": {sid}, "tvshow_id": {"2"}}).listTitles(t, "tvshow_episode")
	if len(eps) != 0 || total != 0 {
		t.Errorf("Mature episodes for the kid profile = %v (total %d), want none", eps, total)
	}
	if r := pcCall(t, e.s.handleWebAPITVShow, "getinfo", url.Values{"_sid": {sid}, "id": {"2"}}); r.Success || r.Error.Code != webAPIErrNoPermission {
		t.Errorf("getinfo on the hidden split show: success=%v code=%d, want %d", r.Success, r.Error.Code, webAPIErrNoPermission)
	}
}
