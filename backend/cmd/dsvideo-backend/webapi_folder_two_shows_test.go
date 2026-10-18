package main

// TASK-999 — a folder holding episodes of more than one show. The web plane resolves a
// folder to ONE show the same way the apps' API does (groupEpisodesByShow: the folder's
// majority show_name names it), so the two planes can never disagree about what a folder
// is. This pins that: the minority episodes follow their folder, the other folder is its
// own show, and every episode appears in exactly one show's list.

import (
	"encoding/json"
	"net/url"
	"strconv"
	"testing"
)

func TestWebAPIFolderHoldingTwoShowsIsOneShowLikeTheApps(t *testing.T) {
	e := newQAEnv(t)
	e.s.cfg.TVPath = "/tv"
	at := "2026-01-01T00:00:00Z"
	// /tv/Daredevil holds 3 episodes of one show and 2 of a sequel series.
	for _, id := range []string{"dd1", "dd2", "dd3"} {
		e.pcTitle(id, "lib_tv", "episode", "/tv/Daredevil/"+id+".mkv", "Marvel's Daredevil", "Drama", at, nil)
	}
	for _, id := range []string{"ba1", "ba2"} {
		e.pcTitle(id, "lib_tv", "episode", "/tv/Daredevil/"+id+".mkv", "Daredevil: Born Again", "Drama", at, nil)
	}
	// The sequel's own folder.
	e.pcTitle("ba3", "lib_tv", "episode", "/tv/Born Again/ba3.mkv", "Daredevil: Born Again", "Drama", at, nil)
	sid := pcSession(t, qaAlice)

	list := pcCall(t, e.s.handleWebAPITVShow, "list", url.Values{"_sid": {sid}})
	var shows []struct {
		ID    int    `json:"id"`
		Title string `json:"title"`
	}
	if err := json.Unmarshal(list.Data["tvshow"], &shows); err != nil {
		t.Fatal(err)
	}
	if len(shows) != 2 {
		t.Fatalf("show list = %s, want exactly 2 shows", list.Data["tvshow"])
	}
	if shows[0].ID == shows[1].ID {
		t.Fatalf("two shows share id %d: %s", shows[0].ID, list.Data["tvshow"])
	}

	want := map[string][]string{
		"Marvel's Daredevil":    {"ba1", "ba2", "dd1", "dd2", "dd3"}, // listed in title order; the folder follows its majority show
		"Daredevil: Born Again": {"ba3"},
	}
	seen := map[string]int{}
	for _, s := range shows {
		w, ok := want[s.Title]
		if !ok {
			t.Fatalf("unexpected show %q in %s", s.Title, list.Data["tvshow"])
		}
		eps, total := pcCall(t, e.s.handleWebAPITVShowEpisode, "list",
			url.Values{"_sid": {sid}, "tvshow_id": {strconv.Itoa(s.ID)}}).listTitles(t, "tvshow_episode")
		if !sameStrings(eps, w) || total != len(w) {
			t.Errorf("%q episodes = %v (total %d), want %v", s.Title, eps, total, w)
		}
		for _, id := range eps {
			seen[id]++
		}
	}
	for _, id := range []string{"dd1", "dd2", "dd3", "ba1", "ba2", "ba3"} {
		if seen[id] != 1 {
			t.Errorf("episode %s appears in %d shows, want exactly 1", id, seen[id])
		}
	}
}
