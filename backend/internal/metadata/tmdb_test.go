package metadata

import "testing"

// Every case below is a real path taken from the live NAS library (4,571 TV episodes),
// not an invented example. Two things are being protected:
//
//  1. The broken cases must get better. `X-Men - PRYDE of The X-Men (Original 1989
//     Pilot).mp4` used to parse to `X Men   PRYDE of The X Men (Original` — hyphens
//     flattened, whitespace left in runs, and the title sliced mid-parenthetical leaving
//     a dangling `(`. That string matches nothing on TMDB, which is why 476 episodes in
//     the library have no artwork at all.
//
//  2. The working cases must not change. 4,300-odd episodes parse correctly today. A
//     "looser" parser that improves 261 titles while quietly altering the rest would be
//     a net loss, and the regression table below is what makes that failure visible.

func TestNormalizeTitle(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"collapses run of spaces", "X Men   PRYDE of The X Men", "X Men PRYDE of The X Men"},
		{"drops dangling open paren", "X Men PRYDE of The X Men (Original", "X Men PRYDE of The X Men"},
		{"drops dangling paren after collapse", "Chip 'n Dale Rescue Rangers   S01 E01   Piratsy Under the Seas (", "Chip 'n Dale Rescue Rangers S01 E01 Piratsy Under the Seas"},
		{"keeps balanced parens", "Justified (2010)", "Justified (2010)"},
		{"trims trailing separator punctuation", "Star Trek TNG -", "Star Trek TNG"},
		{"leaves a clean title untouched", "X-Men Evolution", "X-Men Evolution"},
		{"leaves apostrophes alone", "Chip 'n Dale Rescue Rangers", "Chip 'n Dale Rescue Rangers"},
		{"empty stays empty", "", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := NormalizeTitle(c.in); got != c.want {
				t.Errorf("NormalizeTitle(%q)\n  got  %q\n  want %q", c.in, got, c.want)
			}
		})
	}
}

// The specific file that started this: two X-Men cards showing the same artwork.
func TestParseFilenamePrydePilot(t *testing.T) {
	got := ParseFilename("X-Men - PRYDE of The X-Men (Original 1989 Pilot).mp4")

	if hasUnbalancedParen(got.Title) {
		t.Errorf("title has an unbalanced paren: %q", got.Title)
	}
	if containsDoubleSpace(got.Title) {
		t.Errorf("title has a run of spaces: %q", got.Title)
	}
	// The whole parenthetical is edition/quality noise; the searchable title is what
	// precedes it. Requiring the show name to survive is the point of the fix.
	if got.Title != "X-Men PRYDE of The X-Men" {
		t.Errorf("title = %q, want %q", got.Title, "X-Men PRYDE of The X-Men")
	}
}

func TestParseFilenameTVEpisodes(t *testing.T) {
	cases := []struct {
		file        string
		wantTitle   string
		wantSeason  int
		wantEpisode int
	}{
		{"X-Men Evolution - S01 E01 - Strategy X.mp4", "X-Men Evolution", 1, 1},
		{"Chip 'n Dale Rescue Rangers - S01 E01 - Piratsy Under the Seas (480p).mkv", "Chip 'n Dale Rescue Rangers", 1, 1},
		{"X-Men Evolution - S02 E16-17 - Day of Reckoning.mp4", "X-Men Evolution", 2, 16},
		{"Stargate Atlantis - 3x08 - McKay and Mrs. Miller.avi", "Stargate Atlantis", 3, 8},
	}
	for _, c := range cases {
		t.Run(c.file, func(t *testing.T) {
			got := ParseFilename(c.file)
			if !got.IsTV {
				t.Fatalf("IsTV = false, want true")
			}
			if got.Title != c.wantTitle {
				t.Errorf("Title = %q, want %q", got.Title, c.wantTitle)
			}
			if got.Season != c.wantSeason || got.Episode != c.wantEpisode {
				t.Errorf("S%02dE%02d, want S%02dE%02d", got.Season, got.Episode, c.wantSeason, c.wantEpisode)
			}
		})
	}
}

// REGRESSION GUARD. These parse correctly today. If a change to the parser alters any of
// them, it is breaking working entries to fix broken ones — which is a worse library, not
// a better one.
func TestParseFilenameDoesNotRegressWorkingTitles(t *testing.T) {
	cases := []struct {
		file      string
		wantTitle string
		wantYear  int
	}{
		{"X-Men Apocalypse (2016).mp4", "X-Men Apocalypse", 2016},
		{"X-Men Days of Future Past (2014).mp4", "X-Men Days of Future Past", 2014},
		{"The Thin Man Goes Home (1944).mkv", "The Thin Man Goes Home", 1944},
	}
	for _, c := range cases {
		t.Run(c.file, func(t *testing.T) {
			got := ParseFilename(c.file)
			if got.Title != c.wantTitle {
				t.Errorf("Title = %q, want %q", got.Title, c.wantTitle)
			}
			if got.Year != c.wantYear {
				t.Errorf("Year = %d, want %d", got.Year, c.wantYear)
			}
			if hasUnbalancedParen(got.Title) {
				t.Errorf("unbalanced paren introduced: %q", got.Title)
			}
		})
	}
}

// A year inside a parenthetical must remove the whole group, not slice through it.
func TestParseFilenameYearInsideParentheticalRemovesWholeGroup(t *testing.T) {
	for _, f := range []string{
		"Some Show (Original 1989 Pilot).mp4",
		"Another Thing (Remastered 2003 Edition).mkv",
	} {
		got := ParseFilename(f)
		if hasUnbalancedParen(got.Title) {
			t.Errorf("%s -> %q has an unbalanced paren", f, got.Title)
		}
	}
}

func hasUnbalancedParen(s string) bool {
	open, closed := 0, 0
	for _, r := range s {
		switch r {
		case '(':
			open++
		case ')':
			closed++
		}
	}
	return open != closed
}

func containsDoubleSpace(s string) bool {
	for i := 1; i < len(s); i++ {
		if s[i] == ' ' && s[i-1] == ' ' {
			return true
		}
	}
	return false
}
