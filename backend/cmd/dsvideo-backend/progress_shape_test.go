package main

// TASK-1061 (Rule 9): the per-item progress object {durationSeconds, positionSeconds,
// updatedAt} is built by ONE function (progressRecord.JSON). For the same progress row every
// site that emits it must produce byte-identical JSON; a site that hand-builds it again, or
// drifts in a field name, a type or the absent rule, fails here. The expected bytes are a
// literal, so this also pins the wire shape that existed before the fold (sorted keys, bare
// integers, an RFC 3339 string).

import (
	"encoding/json"
	"fmt"
	"testing"
)

// progressNodes collects, marshalled, every "progress" value whose sibling "id" is itemID
// (list elements: /items, /sync/items, /watchlist, tv episodes, ...).
func progressNodes(t *testing.T, node any, itemID string, out *[]string) {
	t.Helper()
	switch n := node.(type) {
	case map[string]any:
		if id, _ := n["id"].(string); id == itemID {
			if p, ok := n["progress"]; ok && p != nil {
				b, err := json.Marshal(p)
				if err != nil {
					t.Fatalf("marshal progress: %v", err)
				}
				*out = append(*out, string(b))
			}
		}
		for _, c := range n {
			progressNodes(t, c, itemID, out)
		}
	case []any:
		for _, c := range n {
			progressNodes(t, c, itemID, out)
		}
	}
}

func TestTASK1061_EveryProgressSiteEmitsIdenticalJSON(t *testing.T) {
	e, profile, _ := parityEnv(t)

	for _, id := range []string{parMovie, parEpisode} {
		var updatedAt string
		if err := e.db.QueryRow(`SELECT updated_at FROM progress WHERE item_id = ? AND profile_id = ?`,
			id, profile).Scan(&updatedAt); err != nil {
			t.Fatalf("read the progress row of %s: %v", id, err)
		}
		want := fmt.Sprintf(`{"durationSeconds":5400,"positionSeconds":60,"updatedAt":%q}`, updatedAt)

		// Element sites: the progress sits on the list element with this id.
		element := []string{
			"/items?libraryId=lib_movies", "/items?libraryId=lib_tv",
			"/sync/items?since=0",
			"/watchlist", "/downloads",
			"/tv/shows/" + parShow + "/episodes",
			"/tv/shows/" + parShow + "/seasons",
		}
		covered := 0
		for _, path := range element {
			r := e.do(qaAlice, "GET", path, "", profile)
			wantOK(t, r, 200)
			var got []string
			progressNodes(t, r.js, id, &got)
			for _, g := range got {
				covered++
				if g != want {
					t.Errorf("GET %s: progress of %s = %s, want %s", path, id, g, want)
				}
			}
		}
		if covered < 4 {
			t.Errorf("only %d element sites carried progress for %s: the comparison has no teeth", covered, id)
		}

		// Map sites: progress keyed by item id.
		for _, path := range []string{"/progress?ids=" + id, "/progress/all"} {
			r := e.do(qaAlice, "GET", path, "", profile)
			wantOK(t, r, 200)
			m, _ := r.js["progress"].(map[string]any)
			p, ok := m[id]
			if !ok {
				t.Errorf("GET %s lacks %s: %s", path, id, r.raw)
				continue
			}
			b, _ := json.Marshal(p)
			if string(b) != want {
				t.Errorf("GET %s: progress of %s = %s, want %s", path, id, b, want)
			}
		}

		// Go-level sites (playback resume and the web API read these directly).
		single, err := e.s.getProfileProgress(profile, id)
		if err != nil || single == nil {
			t.Fatalf("getProfileProgress(%s) = %v, %v", id, single, err)
		}
		if b, _ := json.Marshal(single.JSON()); string(b) != want {
			t.Errorf("getProfileProgress: %s, want %s", b, want)
		}
		rec, ok := e.s.getProfileProgressBatch(profile, []string{id})[id]
		if !ok {
			t.Fatalf("getProfileProgressBatch lacks %s", id)
		}
		if b, _ := json.Marshal(rec.JSON()); string(b) != want {
			t.Errorf("getProfileProgressBatch: %s, want %s", b, want)
		}
	}

	// The absent rule is shared: a title with no progress row carries no progress key.
	for _, path := range []string{"/items?libraryId=lib_movies", "/sync/items?since=0"} {
		r := e.do(qaAlice, "GET", path, "", profile)
		wantOK(t, r, 200)
		var got []string
		progressNodes(t, r.js, parFreeMovie, &got)
		if len(got) != 0 {
			t.Errorf("GET %s: %s has no progress row but carries %v", path, parFreeMovie, got)
		}
	}
}
