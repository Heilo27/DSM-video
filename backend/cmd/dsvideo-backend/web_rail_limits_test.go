package main

// TASK-920 (FR-088 / FR-145): the server decides how many titles a Home rail holds. The /web
// player used to send its own number (20, against the server's 16), so the browser showed a
// longer Just Added rail than the iPhone and Apple TV for the same library. The page now
// omits `limit` and takes the server's default, so there is one home for the number.

import (
	"fmt"
	"net/http"
	"regexp"
	"testing"
	"time"
)

func TestWebPlayerLeavesRailSizeToTheServer(t *testing.T) {
	page, err := webContent.ReadFile("web/index.html")
	if err != nil {
		t.Fatalf("embedded web/index.html: %v", err)
	}
	// Any rail request in the page that pins its own size is a second copy of the rule.
	pinned := regexp.MustCompile(`/api/v1/(just-added|suggested)[^'"` + "`" + `]*limit=`)
	if m := pinned.FindString(string(page)); m != "" {
		t.Errorf("the web player pins a rail size (%q); the server's default is the rule (FR-088)", m)
	}
	for _, rail := range []string{"/api/v1/just-added", "/api/v1/suggested"} {
		if !regexp.MustCompile(regexp.QuoteMeta(rail)).Match(page) {
			t.Errorf("the web player no longer requests %s", rail)
		}
	}
}

// What the web player now gets when it sends no limit: the FR-088 cap of 16.
func TestJustAddedDefaultsToSixteenWhenNoLimitIsSent(t *testing.T) {
	e := newQAEnv(t)
	for i := 0; i < 30; i++ {
		e.pcTitle(fmt.Sprintf("m%02d", i), "lib_movies", "movie", fmt.Sprintf("/movies/m%02d.mkv", i), "", "Drama",
			time.Date(2026, 1, 1, 0, i, 0, 0, time.UTC).Format(time.RFC3339), sp("G"))
	}
	r := e.do(qaAlice, http.MethodGet, "/just-added", "", "")
	wantOK(t, r, http.StatusOK)
	items, _ := r.js["items"].([]any)
	if len(items) != 16 {
		t.Errorf("/just-added with no limit returned %d titles, want 16 (FR-088)", len(items))
	}
}
