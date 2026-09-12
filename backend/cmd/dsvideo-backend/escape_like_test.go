package main

import (
	"database/sql"
	"path/filepath"
	"testing"

	_ "modernc.org/sqlite"
)

// handleSearch took END-USER text and built `"%" + q + "%"` with no escaping and no ESCAPE
// clause, so '%' and '_' were live LIKE wildcards: searching "%" returned the ENTIRE library
// and "50% Off" silently over-matched. Six other LIKE sites escaped correctly, each with its
// own open-coded copy of the same three lines — so there was no single definition of the rule
// and the one query taking user input was the one that forgot.
//
// Expected values are hardcoded, never re-derived with escapeLike's own expression: a test
// that recomputes the answer the same way the implementation does cannot detect a wrong rule.
func TestEscapeLike(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"plain text passes through untouched", "Daredevil", "Daredevil"},
		{"empty string stays empty", "", ""},
		{"bare percent is escaped, not a wildcard", "%", `\%`},
		{"bare underscore is escaped, not a single-char wildcard", "_", `\_`},
		{"backslash is doubled", `\`, `\\`},
		// Order matters. The backslash pass must run FIRST. If '%' were escaped first the
		// backslash pass would then double the backslash it just inserted, producing \\% —
		// a literal backslash followed by a live wildcard, i.e. worse than doing nothing.
		{"backslash before percent does not double-escape", `\%`, `\\\%`},
		{"backslash before underscore does not double-escape", `\_`, `\\\_`},
		{"combination of all three metacharacters", `a%b_c\d`, `a\%b\_c\\d`},
		// The realistic defect report.
		{"a 50% Off style title", "50% Off", `50\% Off`},
		{"a snake_case title", "star_wars", `star\_wars`},
		{"multiple percents", "%%", `\%\%`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := escapeLike(c.in); got != c.want {
				t.Errorf("escapeLike(%q) = %q, want %q", c.in, got, c.want)
			}
		})
	}
}

// The search pattern is what actually reaches SQLite. The surrounding '%' wildcards are
// DELIBERATELY unescaped — they are the substring match — while everything from the user is
// escaped. Getting this wrapping wrong in either direction breaks search, so pin it.
func TestSearchPatternEscapesOnlyTheUserText(t *testing.T) {
	if got := "%" + escapeLike("50% Off") + "%"; got != `%50\% Off%` {
		t.Errorf("search pattern = %q, want %q", got, `%50\% Off%`)
	}
	// The report's worst case: a lone '%' must no longer mean "everything".
	if got := "%" + escapeLike("%") + "%"; got != `%\%%` {
		t.Errorf("search pattern for %q = %q, want %q", "%", got, `%\%%`)
	}
}

// showFolderWhere builds the detail-side predicate. It must carry an ESCAPE clause per
// folder, and must stay parenthesised so a caller can AND `library_id = 'lib_tv'` onto it
// without the OR chain swallowing that predicate and returning the whole library.
func TestShowFolderWhereEscapesAndParenthesises(t *testing.T) {
	where, args := showFolderWhere([]string{"Show_A", "Show (2015)"}, "/tv/")

	wantWhere := `(path LIKE ? ESCAPE '\' OR path LIKE ? ESCAPE '\')`
	if where != wantWhere {
		t.Errorf("where = %q, want %q", where, wantWhere)
	}
	if len(args) != 2 {
		t.Fatalf("args = %d, want 2", len(args))
	}
	if args[0] != `/tv/Show\_A/%` {
		t.Errorf("args[0] = %q, want %q", args[0], `/tv/Show\_A/%`)
	}
	if args[1] != "/tv/Show (2015)/%" {
		t.Errorf("args[1] = %q, want %q", args[1], "/tv/Show (2015)/%")
	}
}

// A single-folder show — the overwhelming majority — must produce exactly the same single
// predicate it always did, so the merge fix cannot regress the common path.
func TestShowFolderWhereSingleFolderIsUnchanged(t *testing.T) {
	where, args := showFolderWhere([]string{"Daredevil"}, "/tv/")
	if where != `(path LIKE ? ESCAPE '\')` {
		t.Errorf("where = %q", where)
	}
	if len(args) != 1 || args[0] != "/tv/Daredevil/%" {
		t.Errorf("args = %v", args)
	}
}

// The Go string being right is not the same as the QUERY being right: the ESCAPE clause has
// to actually reach SQLite, and the COUNT query and the row query have to agree. This drives
// real SQLite with the same pattern and clause handleSearch uses.
func TestSearchEscapeAgainstRealSQLite(t *testing.T) {
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "q.db"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	if _, err := db.Exec(`CREATE TABLE items(title TEXT)`); err != nil {
		t.Fatalf("schema: %v", err)
	}
	for _, title := range []string{"50% Off Sale", "Star Wars", "star_wars", "starXwars", "Daredevil"} {
		if _, err := db.Exec(`INSERT INTO items VALUES(?)`, title); err != nil {
			t.Fatalf("insert: %v", err)
		}
	}

	count := func(q string) int {
		var n int
		db.QueryRow(`SELECT COUNT(*) FROM items WHERE LOWER(title) LIKE LOWER(?) ESCAPE '\'`,
			"%"+escapeLike(q)+"%").Scan(&n)
		return n
	}

	// THE DEFECT: searching "%" returned the entire library. Now it matches only the one
	// title that actually contains a percent sign.
	if n := count("%"); n != 1 {
		t.Errorf(`searching "%%" matched %d rows, want 1 (only "50%% Off Sale")`, n)
	}
	if n := count("50%"); n != 1 {
		t.Errorf(`searching "50%%" matched %d rows, want 1`, n)
	}
	// '_' must not act as a single-character wildcard: "star_wars" must not match "starXwars".
	if n := count("star_wars"); n != 1 {
		t.Errorf(`searching "star_wars" matched %d rows, want 1 (not "starXwars")`, n)
	}
	// Ordinary substring search is unaffected — escaping must not break the feature.
	if n := count("Star"); n != 3 {
		t.Errorf(`searching "Star" matched %d rows, want 3`, n)
	}
	if n := count("Daredevil"); n != 1 {
		t.Errorf(`searching "Daredevil" matched %d rows, want 1`, n)
	}
}
