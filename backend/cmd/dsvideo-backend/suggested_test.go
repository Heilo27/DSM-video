package main

import (
	"database/sql"
	"strings"
	"testing"
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
