package main

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// The Suggested rail replaces Recently Watched, which required an item past 95% complete
// (isFinished) and so could never show anything stopped partway. Against the live library
// that meant Aladdin at 68%, 1776 at 55% and A League of Their Own at 62% were all invisible
// to it while it showed the two things actually finished.

func TestPickSuggestionGenrePrefersTheSpecificOne(t *testing.T) {
	// Aladdin's real genres from the live server.
	if got := pickSuggestionGenre("Animation, Family, Adventure, Fantasy, Romance"); got != "Animation" {
		t.Errorf("got %q, want Animation — the broad genres should be skipped", got)
	}
	// Order matters: the FIRST non-broad entry wins, not merely any of them.
	if got := pickSuggestionGenre("Drama,Action,Western"); got != "Western" {
		t.Errorf("got %q, want Western", got)
	}
	if got := pickSuggestionGenre("Comedy, Documentary"); got != "Documentary" {
		t.Errorf("got %q, want Documentary", got)
	}
}

// A broad suggestion still beats an empty rail, so an all-broad list must not give up.
func TestPickSuggestionGenreFallsBackWhenAllAreBroad(t *testing.T) {
	if got := pickSuggestionGenre("Drama"); got != "Drama" {
		t.Errorf("got %q, want Drama as the fallback", got)
	}
	if got := pickSuggestionGenre("Action, Thriller"); got != "Action" {
		t.Errorf("got %q, want the first as the fallback", got)
	}
}

func TestPickSuggestionGenreHandlesEmptyInput(t *testing.T) {
	for _, in := range []string{"", "   ", ",", " , , "} {
		if got := pickSuggestionGenre(in); got != "" {
			t.Errorf("pickSuggestionGenre(%q) = %q, want empty", in, got)
		}
	}
}

// The client applies the same rule when falling back to the two-request path against an
// older server. If the two lists drift, the rail's subtitle names a different genre than the
// items were chosen from.
func TestBroadGenreListMatchesTheClient(t *testing.T) {
	// Mirrors AppState.suggestionGenre's `tooBroad` set exactly.
	want := []string{"Drama", "Comedy", "Action", "Thriller", "Adventure"}
	if len(broadGenres) != len(want) {
		t.Fatalf("broadGenres has %d entries, client has %d — they must agree",
			len(broadGenres), len(want))
	}
	for _, g := range want {
		if !broadGenres[g] {
			t.Errorf("client treats %q as broad; server does not", g)
		}
	}
}

// The genre column is comma-separated, so matching must not be a naive substring test:
// "Action" must not match "Live Action", and "War" must not match "Warrior".
func TestGenreMatchingIsWholeValueNotSubstring(t *testing.T) {
	// Reproduces the padded-LIKE predicate the handler builds.
	matches := func(itemGenres, wanted string) bool {
		padded := "," + strings.ReplaceAll(itemGenres, ", ", ",") + ","
		return strings.Contains(padded, ","+wanted+",")
	}

	if !matches("Animation, Family, Adventure", "Family") {
		t.Error("a genuine match was rejected")
	}
	if !matches("Action", "Action") {
		t.Error("a single-genre item did not match itself")
	}
	if matches("Live Action, Comedy", "Action") {
		t.Error(`"Action" matched "Live Action" — substring bug`)
	}
	if matches("Warrior", "War") {
		t.Error(`"War" matched "Warrior" — substring bug`)
	}
	if matches("Science Fiction", "Fiction") {
		t.Error(`"Fiction" matched "Science Fiction" — substring bug`)
	}
}

// A genre containing a LIKE wildcard must not widen the match — the same class of bug as
// TASK-901, where an unescaped "%" in search returned the entire library.
func TestGenrePatternEscapesLikeWildcards(t *testing.T) {
	if got := escapeLike("100% Fun"); !strings.Contains(got, `\%`) {
		t.Errorf("escapeLike(%q) = %q — the wildcard is not escaped", "100% Fun", got)
	}
	if got := escapeLike("Sci_Fi"); !strings.Contains(got, `\_`) {
		t.Errorf("escapeLike(%q) = %q — the single-char wildcard is not escaped", "Sci_Fi", got)
	}
}

// sql.NullString is used by the seed query; a NULL genres column must not panic or produce
// a bogus genre.
func TestNullGenresYieldsNoSuggestion(t *testing.T) {
	var ns sql.NullString
	if got := pickSuggestionGenre(ns.String); got != "" {
		t.Errorf("a NULL genres column produced %q", got)
	}
}

// /suggested must complete on a single pooled connection.
//
// A cursor holds a pool connection while it is drained, so a query issued INSIDE rows.Next()
// needs a second one. Under concurrency every connection ends up held by a cursor whose
// goroutine waits for a connection that only frees when a cursor closes, and nothing
// proceeds. That exact defect shipped three times in this codebase (870636b fixed the last
// three instances), so a new handler that opens a cursor gets pinned the moment it is added
// rather than after the next outage.
//
// Pinning the pool to ONE connection is the whole point: with more available the defective
// shape merely gets slow, and the test would pass against the bug.
func TestSuggestedCompletesOnASingleConnection(t *testing.T) {
	s := singleConnServer(t, 4)

	// Give the user progress on one item with genres, so the seed query returns something
	// and the handler proceeds to open its cursor — otherwise it short-circuits and the
	// test would prove nothing.
	if _, err := s.db.Exec(
		`INSERT INTO items(id, library_id, type, title, genres, added_at, duration_seconds)
		 VALUES('seed', 'lib_movies', 'movie', 'Seed Film', 'Animation,Family', '2026-01-01T00:00:00Z', 6000)`,
	); err != nil {
		t.Fatalf("insert seed: %v", err)
	}
	if _, err := s.db.Exec(
		`INSERT INTO progress(item_id, user_id, position_seconds, duration_seconds, updated_at, write_seq)
		 VALUES('seed', 'u1', 300, 6000, '2026-09-15T21:00:00Z', 1)`,
	); err != nil {
		t.Fatalf("insert progress: %v", err)
	}
	// And candidates in the same genre for the cursor to actually iterate.
	for i := 0; i < 5; i++ {
		id := "cand" + string(rune('A'+i))
		if _, err := s.db.Exec(
			`INSERT INTO items(id, library_id, type, title, genres, added_at, duration_seconds)
			 VALUES(?, 'lib_movies', 'movie', ?, 'Animation,Family', '2026-01-01T00:00:00Z', 6000)`,
			id, "Candidate "+id,
		); err != nil {
			t.Fatalf("insert candidate: %v", err)
		}
	}

	req := authedReq(http.MethodGet, "/suggested?libraryId=lib_movies", "u1")
	rec := httptest.NewRecorder()

	// A deadlock test must never be able to wedge the suite: run the handler in a goroutine
	// behind a timeout so a regression FAILS loudly instead of hanging CI forever.
	done := make(chan struct{})
	go func() {
		defer close(done)
		s.handleSuggested(rec, req)
	}()

	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("handleSuggested did not complete on a single connection — it is querying " +
			"inside an open cursor, which deadlocks the pool under concurrency")
	}

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}

	var resp struct {
		Genre string           `json:"genre"`
		Items []map[string]any `json:"items"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	// Animation over Family: both are on the seed, and Family is not broad either, but
	// Animation comes first — the rule takes the FIRST non-broad genre.
	if resp.Genre != "Animation" {
		t.Errorf("genre = %q, want Animation", resp.Genre)
	}
	if len(resp.Items) == 0 {
		t.Error("no items returned, so the cursor was never exercised")
	}
	// The seed itself must not be suggested back — the viewer is already watching it.
	for _, it := range resp.Items {
		if it["id"] == "seed" {
			t.Error("suggested an item the viewer already has progress on")
		}
	}
}
