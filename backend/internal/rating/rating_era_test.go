package rating_test

// FRD-002 FR-241a (TASK-1068, Ryan 2026-10-18): a film rated PG with a release year of 1984
// or earlier gates at Teens (3); PG-13 only arrived in August 1984. Every expected level below
// is a literal from that decision; nothing computes its expectation with the package.

import (
	"database/sql"
	"strings"
	"testing"

	"dsvideo/backend/internal/rating"

	_ "modernc.org/sqlite"
)

func ip(n int) *int { return &n }

func TestFR241a_ItemLevel(t *testing.T) {
	cases := []struct {
		name  string
		cert  *string
		typ   string
		year  *int
		level int
	}{
		{"PG movie 1984 is Teens", sp("PG"), "movie", ip(1984), 3},
		{"PG movie 1975 is Teens", sp("PG"), "movie", ip(1975), 3},
		{"PG movie year 0 is Teens", sp("PG"), "movie", ip(0), 3},
		{"PG movie 1985 is Older Kids", sp("PG"), "movie", ip(1985), 2},
		{"PG movie 2020 is Older Kids", sp("PG"), "movie", ip(2020), 2},
		{"PG movie with no year keeps Older Kids", sp("PG"), "movie", nil, 2},
		{"pg lowercase padded 1984", sp("  pg\t"), "movie", ip(1984), 3},
		{"PG episode 1980 is unchanged", sp("PG"), "episode", ip(1980), 2},
		{"PG with unknown type is unchanged", sp("PG"), "", ip(1980), 2},
		{"G 1950 is unchanged", sp("G"), "movie", ip(1950), 1},
		{"PG-13 1984 is unchanged", sp("PG-13"), "movie", ip(1984), 3},
		{"R 1970 is unchanged", sp("R"), "movie", ip(1970), 4},
		{"NC-17 1970 is unchanged", sp("NC-17"), "movie", ip(1970), 4},
		{"TV-PG 1980 movie is unchanged", sp("TV-PG"), "movie", ip(1980), 2},
		{"TV-PG 1980 episode is unchanged", sp("TV-PG"), "episode", ip(1980), 2},
		{"TV-14 episode unchanged", sp("TV-14"), "episode", ip(1980), 3},
		{"unrated 1970 stays fail-closed", nil, "movie", ip(1970), 4},
		{"unknown cert 1970 stays fail-closed", sp("NR"), "movie", ip(1970), 4},
	}
	for _, c := range cases {
		if got := rating.ItemLevel(c.cert, c.typ, c.year); got != c.level {
			t.Errorf("%s: ItemLevel = %d, want %d", c.name, got, c.level)
		}
	}
}

func sp(s string) *string { return &s }

// The SQL twin and the Go function must agree for every combination (ADR-001 decision 1).
func TestFR241a_SQLItemLevelAgreesWithGo(t *testing.T) {
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(`CREATE TABLE items (id INTEGER PRIMARY KEY, content_rating TEXT, type TEXT, year INTEGER)`); err != nil {
		t.Fatal(err)
	}
	certs := []*string{nil, sp(""), sp("G"), sp("PG"), sp(" pg "), sp("Pg\n"), sp("PG-13"), sp("R"), sp("NC-17"),
		sp("TV-PG"), sp("TV-MA"), sp("TV-Y7"), sp("NR"), sp("PG13")}
	types := []string{"movie", "episode", "", "Movie"}
	years := []*int{nil, ip(0), ip(1920), ip(1983), ip(1984), ip(1985), ip(2026)}

	type row struct {
		cert *string
		typ  string
		year *int
	}
	var rows []row
	for _, c := range certs {
		for _, ty := range types {
			for _, y := range years {
				rows = append(rows, row{c, ty, y})
			}
		}
	}
	for i, r := range rows {
		var cert any
		if r.cert != nil {
			cert = *r.cert
		}
		var year any
		if r.year != nil {
			year = *r.year
		}
		if _, err := db.Exec(`INSERT INTO items(id, content_rating, type, year) VALUES (?,?,?,?)`, i, cert, r.typ, year); err != nil {
			t.Fatal(err)
		}
	}
	expr := rating.SQLItemLevel("content_rating")
	rs, err := db.Query("SELECT id, " + expr + " FROM items")
	if err != nil {
		t.Fatalf("query: %v\nexpr: %s", err, expr)
	}
	defer rs.Close()
	n := 0
	for rs.Next() {
		var id, lv int
		if err := rs.Scan(&id, &lv); err != nil {
			t.Fatal(err)
		}
		r := rows[id]
		if want := rating.ItemLevel(r.cert, r.typ, r.year); lv != want {
			t.Errorf("DRIFT cert=%v type=%q year=%v: SQL=%d Go=%d", r.cert, r.typ, r.year, lv, want)
		}
		n++
	}
	if n != len(rows) {
		t.Fatalf("scanned %d rows, want %d", n, len(rows))
	}
}

// VisibleItems filters by the era-aware level: at the Older Kids ceiling a 1984 PG film is
// hidden and a 1985 one is shown; at Teens both are shown; unrestricted adds no clause.
func TestFR241a_VisibleItemsFiltersEraTitles(t *testing.T) {
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(`CREATE TABLE items (id TEXT, content_rating TEXT, type TEXT, year INTEGER);
		INSERT INTO items VALUES ('pg84','PG','movie',1984), ('pg85','PG','movie',1985),
		('pgnone','PG','movie',NULL), ('g50','G','movie',1950), ('pgep','PG','episode',NULL);`); err != nil {
		t.Fatal(err)
	}
	ids := func(ceiling int) string {
		clause, args := rating.VisibleItems("i.content_rating", ceiling)
		q := "SELECT i.id FROM items i"
		if clause != "" {
			q += " WHERE " + clause
		}
		q += " ORDER BY i.id"
		rs, err := db.Query(q, args...)
		if err != nil {
			t.Fatalf("ceiling %d: %v\n%s", ceiling, err, q)
		}
		defer rs.Close()
		var out []string
		for rs.Next() {
			var id string
			if err := rs.Scan(&id); err != nil {
				t.Fatal(err)
			}
			out = append(out, id)
		}
		return strings.Join(out, ",")
	}
	if got, want := ids(2), "g50,pg85,pgep,pgnone"; got != want {
		t.Errorf("Older Kids ceiling = %s, want %s (1984 PG hidden)", got, want)
	}
	if got, want := ids(3), "g50,pg84,pg85,pgep,pgnone"; got != want {
		t.Errorf("Teens ceiling = %s, want %s", got, want)
	}
	if got, want := ids(1), "g50"; got != want {
		t.Errorf("Little Kids ceiling = %s, want %s", got, want)
	}
	if clause, args := rating.VisibleItems("i.content_rating", 4); clause != "" || args != nil {
		t.Errorf("unrestricted = %q %v, want no clause", clause, args)
	}
}

// ItemCols derives the sibling columns under the same qualifier and refuses anything that is
// not a content_rating column (it is spliced into SQL).
func TestFR241a_ItemColsQualifiersAndRejects(t *testing.T) {
	for _, c := range []struct{ in, cert, typ, year string }{
		{"content_rating", "content_rating", "type", "year"},
		{"i.content_rating", "i.content_rating", "i.type", "i.year"},
		{"vis_i.content_rating", "vis_i.content_rating", "vis_i.type", "vis_i.year"},
	} {
		cert, typ, year := rating.ItemCols(c.in)
		if cert != c.cert || typ != c.typ || year != c.year {
			t.Errorf("ItemCols(%q) = %q %q %q", c.in, cert, typ, year)
		}
	}
	for _, bad := range []string{"", "title", "x_content_rating", "content_rating; DROP TABLE items", "i.title", "a.b.title", "content_ratingx"} {
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("ItemCols(%q) did not panic", bad)
				}
			}()
			rating.ItemCols(bad)
		}()
	}
}

// The era rules are part of the fingerprinted Levels, so shipping them moves the FR-244
// fingerprint (the one-time recompute), and a pre-era snapshot decodes to the ladder alone.
func TestFR241a_EraRulesAreInTheFingerprintedLevels(t *testing.T) {
	live := rating.CurrentLevels()
	if len(live.Era) != 1 || live.Era[0].Cert != "PG" || live.Era[0].ItemType != "movie" ||
		live.Era[0].ThroughYear != 1984 || live.Era[0].Level != 3 {
		t.Fatalf("live era rules = %+v, want exactly PG/movie/<=1984 -> 3", live.Era)
	}
	if live.Fingerprint() == live.WithoutEra().Fingerprint() {
		t.Error("fingerprint ignores the era rules: an upgrade would not trigger the recompute")
	}
	old, err := rating.DecodeLevels(live.WithoutEra().Encode())
	if err != nil {
		t.Fatal(err)
	}
	if got := old.ItemLevel(sp("PG"), "movie", ip(1984)); got != 2 {
		t.Errorf("pre-era snapshot ItemLevel(PG 1984) = %d, want 2", got)
	}
	if got := live.ItemLevel(sp("PG"), "movie", ip(1984)); got != 3 {
		t.Errorf("live snapshot ItemLevel(PG 1984) = %d, want 3", got)
	}
}
