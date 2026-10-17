package rating_test

// Verification of FRD-002 §6 (FR-240..FR-242, AC-002-10) written from the spec table, not
// from rating.go. Every expected value below is a literal copied from the FR-241 table or
// the API doc; no test computes its expectation with the package's own functions, except the
// Go-vs-SQL agreement checks, where agreement between the two homes IS the property (ADR-001
// decision 1: "a generated SQL expression that computes the same level").

import (
	"database/sql"
	"reflect"
	"sort"
	"strings"
	"testing"

	"dsvideo/backend/internal/rating"

	_ "modernc.org/sqlite"
)

// ladderLiterals is the FR-241 table, verbatim.
var ladderLiterals = []struct {
	cert  string
	level int
}{
	{"G", 1}, {"TV-Y", 1}, {"TV-G", 1},
	{"PG", 2}, {"TV-Y7", 2}, {"TV-Y7-FV", 2}, {"TV-PG", 2},
	{"PG-13", 3}, {"TV-14", 3},
	{"R", 4}, {"NC-17", 4}, {"TV-MA", 4},
}

// unratedLiterals must all be level 4 (FR-242: unknown strings fail closed). Includes the
// spec's own examples (X, M, 18, NR) and near-misses of real certifications.
var unratedLiterals = []string{
	"", " ", "\t", "X", "M", "18", "NR", "Not Rated", "Unrated", "NOT RATED", "UR",
	"PG13", "PG 13", "PG-1", "PG-133", "PG-", "TV", "TV-", "TV-Y7-F", "TV-Y7FV", "TV-MA-", "TV14", "NC17",
	"G-", "GG", "R-18", "A", "0", "1", "NULL", "null", "TV-Y77", "TV_14", "pg;13",
	"'; DROP TABLE items; --", "PG' OR '1'='1",
}

func mixedCase(s string) string {
	var b strings.Builder
	for i, r := range s {
		if i%2 == 1 && r >= 'A' && r <= 'Z' {
			r += 'a' - 'A'
		}
		b.WriteRune(r)
	}
	return b.String()
}

// AC-002-10 given each certification in the FR-241 table, in any letter case and with
// surrounding whitespace, when mapped, then that row's level. Mutation: change any one
// table cell (e.g. TV-G to level 2) and its row goes red.
func TestAC00210_EveryLadderCertMapsToItsLevel_CaseAndWhitespaceInsensitive(t *testing.T) {
	pads := [][2]string{{"", ""}, {" ", ""}, {"", " "}, {"  ", "\t"}, {"\n", "\r\n"}, {"\t \n", " \r"}}
	for _, row := range ladderLiterals {
		forms := []string{row.cert, strings.ToLower(row.cert), mixedCase(row.cert)}
		for _, f := range forms {
			for _, p := range pads {
				in := p[0] + f + p[1]
				if got := rating.Level(in); got != row.level {
					t.Errorf("Level(%q) = %d, want %d (FR-241 row %q)", in, got, row.level, row.cert)
				}
			}
		}
	}
}

// AC-002-10 given NULL / unknown strings, then level 4 (FR-242).
func TestAC00210_UnratedAndUnknownAreLevel4(t *testing.T) {
	for _, in := range unratedLiterals {
		if got := rating.Level(in); got != 4 {
			t.Errorf("Level(%q) = %d, want 4 (unknown fails closed, FR-242)", in, got)
		}
	}
	if got := rating.LevelPtr(nil); got != 4 {
		t.Errorf("LevelPtr(nil) = %d, want 4 (NULL is unrated)", got)
	}
	g := "G"
	if got := rating.LevelPtr(&g); got != 1 {
		t.Errorf("LevelPtr(&\"G\") = %d, want 1 (a non-nil pointer must be mapped, not treated as unrated)", got)
	}
	empty := ""
	if got := rating.LevelPtr(&empty); got != 4 {
		t.Errorf("LevelPtr(&\"\") = %d, want 4", got)
	}
}

// Whitespace beyond space/tab/CR/LF (NBSP, VT, FF, zero-width) is not "surrounding
// whitespace" in any way SQLite can reproduce; the safe direction is fail-closed. The
// property asserted is that such strings never LOWER a level versus the same string
// without them being recognised, and that Go and SQL agree (see the agreement test).
func TestAC00210_ExoticWhitespaceNeverUnlocksALowerLevelThanASCIITrimWould(t *testing.T) {
	for _, in := range []string{"G ", " G", "PG​", "TV-Y\x0b", "\x0cPG-13", "ＰＧ", "ｇ", "PG\x00"} {
		if got := rating.Level(in); got != 4 {
			t.Errorf("Level(%q) = %d; exotic whitespace / lookalikes must fail closed to 4", in, got)
		}
	}
}

func openMem(t *testing.T) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	db.SetMaxOpenConns(1) // :memory: is per-connection
	t.Cleanup(func() { db.Close() })
	return db
}

func allInputs() []string {
	var in []string
	for _, r := range ladderLiterals {
		in = append(in, r.cert, strings.ToLower(r.cert), mixedCase(r.cert),
			" "+r.cert+" ", "\t"+strings.ToLower(r.cert)+"\n", "\r\n"+mixedCase(r.cert)+"  ")
	}
	in = append(in, unratedLiterals...)
	in = append(in, "G ", " G", "PG​", "TV-Y\x0b", "\x0cPG-13", "ＰＧ", "ｇ",
		"tv-y7-fv ", " Tv-Ma", "nc-17", "Nc-17\n", "pg-13\t\t", "ı", "ß", "ſ", "Ｒ", "K")
	return in
}

// ADR-001 decision 1 / AC-002-10: Go and SQL are one home. For every input (and NULL) the
// SQL expression evaluated in SQLite equals rating.Level, AND equals the spec literal for
// the table rows. Mutation: edit one WHEN arm or the TRIM set in the SQL generator and the
// agreement fails for that input.
func TestAC00210_SQLLevelAgreesWithGoLevelForEveryInput(t *testing.T) {
	db := openMem(t)
	expr := rating.SQLLevel("c")
	q := "SELECT " + expr + " FROM (SELECT ? AS c)"
	for _, in := range allInputs() {
		var sqlLv int
		if err := db.QueryRow(q, in).Scan(&sqlLv); err != nil {
			t.Fatalf("SQLLevel on %q: %v\nexpr: %s", in, err, expr)
		}
		if goLv := rating.Level(in); sqlLv != goLv {
			t.Errorf("DRIFT for %q: SQLLevel=%d Level=%d", in, sqlLv, goLv)
		}
	}
	// Spec literals evaluated by SQLite itself (not just agreement with Go).
	for _, row := range ladderLiterals {
		for _, in := range []string{row.cert, " " + strings.ToLower(row.cert) + "\t"} {
			var got int
			if err := db.QueryRow(q, in).Scan(&got); err != nil {
				t.Fatal(err)
			}
			if got != row.level {
				t.Errorf("SQL level of %q = %d, want %d", in, got, row.level)
			}
		}
	}
	var null int
	if err := db.QueryRow("SELECT " + expr + " FROM (SELECT NULL AS c)").Scan(&null); err != nil {
		t.Fatal(err)
	}
	if null != 4 {
		t.Errorf("SQL level of NULL = %d, want 4 (FR-242)", null)
	}
	var emptyLv int
	if err := db.QueryRow(q, "").Scan(&emptyLv); err != nil || emptyLv != 4 {
		t.Errorf("SQL level of '' = %d (err %v), want 4", emptyLv, err)
	}
}

// The column may be table-qualified (handlers use i.content_rating); it must work against a
// real items-shaped table and a NULL row, which is how handlers use it.
func TestAC00210_SQLLevelOnQualifiedColumnOfARealTable(t *testing.T) {
	db := openMem(t)
	if _, err := db.Exec(`CREATE TABLE items(id TEXT PRIMARY KEY, content_rating TEXT)`); err != nil {
		t.Fatal(err)
	}
	rows := []struct {
		id   string
		cert any
		want int
	}{
		{"a", "G", 1}, {"b", "pg", 2}, {"c", " PG-13 ", 3}, {"d", "TV-MA", 4}, {"e", nil, 4}, {"f", "X", 4}, {"g", "tv-y7-fv", 2},
	}
	for _, r := range rows {
		if _, err := db.Exec(`INSERT INTO items VALUES(?,?)`, r.id, r.cert); err != nil {
			t.Fatal(err)
		}
	}
	got := map[string]int{}
	rs, err := db.Query("SELECT i.id, " + rating.SQLLevel("i.content_rating") + " FROM items i")
	if err != nil {
		t.Fatal(err)
	}
	defer rs.Close()
	for rs.Next() {
		var id string
		var lv int
		if err := rs.Scan(&id, &lv); err != nil {
			t.Fatal(err)
		}
		got[id] = lv
	}
	for _, r := range rows {
		if got[r.id] != r.want {
			t.Errorf("row %s (%v): level %d, want %d", r.id, r.cert, got[r.id], r.want)
		}
	}
	if len(got) != len(rows) {
		t.Errorf("returned %d rows, want %d", len(got), len(rows))
	}
}

// SQLLevel splices the column name into SQL; anything but a plain identifier must panic
// rather than become an injection point.
func TestSQLLevelRejectsNonIdentifiers(t *testing.T) {
	for _, bad := range []string{"", "a b", "1col", "c); DROP TABLE items; --", "c)--", "i.content_rating OR 1=1", "'x'", "a;b", ".a"} {
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("SQLLevel(%q) did not panic", bad)
				}
			}()
			_ = rating.SQLLevel(bad)
		}()
	}
	for _, ok := range []string{"content_rating", "i.content_rating", "_c1"} {
		func() {
			defer func() {
				if r := recover(); r != nil {
					t.Errorf("SQLLevel(%q) panicked: %v", ok, r)
				}
			}()
			_ = rating.SQLLevel(ok)
		}()
	}
}

// FR-202/FR-242 through the SQL filter: Visible(col, L) keeps exactly the titles at or below
// L, hides NULL and unknown strings on every restricted ceiling, and is empty (no filter)
// at Adult so unrated titles stay visible there (AC-002-14's server half).
func TestAC00210_VisibleFilterKeepsExactlyTitlesAtOrBelowCeiling(t *testing.T) {
	db := openMem(t)
	if _, err := db.Exec(`CREATE TABLE items(id TEXT PRIMARY KEY, content_rating TEXT)`); err != nil {
		t.Fatal(err)
	}
	data := []struct {
		id   string
		cert any
	}{
		{"g", "G"}, {"tvy", "tv-y"}, {"tvg", " TV-G "}, {"pg", "PG"}, {"tvpg", "TV-PG"}, {"y7fv", "TV-Y7-FV"},
		{"pg13", "PG-13"}, {"tv14", "TV-14"}, {"r", "R"}, {"nc17", "NC-17"}, {"tvma", "TV-MA"},
		{"null", nil}, {"x", "X"}, {"nr", "NR"}, {"empty", ""},
	}
	for _, d := range data {
		if _, err := db.Exec(`INSERT INTO items VALUES(?,?)`, d.id, d.cert); err != nil {
			t.Fatal(err)
		}
	}
	want := map[int][]string{
		1: {"g", "tvg", "tvy"},
		2: {"g", "pg", "tvg", "tvpg", "tvy", "y7fv"},
		3: {"g", "pg", "pg13", "tv14", "tvg", "tvpg", "tvy", "y7fv"},
		4: {"empty", "g", "nc17", "nr", "null", "pg", "pg13", "r", "tv14", "tvg", "tvma", "tvpg", "tvy", "x", "y7fv"},
	}
	for level, ids := range want {
		clause, args := rating.Visible("content_rating", level)
		q := "SELECT id FROM items"
		if clause != "" {
			q += " WHERE " + clause
		}
		rs, err := db.Query(q, args...)
		if err != nil {
			t.Fatalf("level %d: %v", level, err)
		}
		var got []string
		for rs.Next() {
			var id string
			_ = rs.Scan(&id)
			got = append(got, id)
		}
		rs.Close()
		sort.Strings(got)
		if !reflect.DeepEqual(got, ids) {
			t.Errorf("ceiling %d visible = %v, want %v", level, got, ids)
		}
	}
	if c, a := rating.Visible("content_rating", 4); c != "" || len(a) != 0 {
		t.Errorf("Visible at Adult = (%q,%v), want no filter at all", c, a)
	}
	if c, _ := rating.Visible("content_rating", 3); c == "" {
		t.Errorf("Visible at level 3 returned no filter")
	}
}

func TestRestrictedAndValidLevelBoundaries(t *testing.T) {
	for lv, want := range map[int]bool{-1: true, 0: true, 1: true, 2: true, 3: true, 4: false, 5: false} {
		if got := rating.Restricted(lv); got != want {
			t.Errorf("Restricted(%d) = %v, want %v (FRD §1: restricted = below Adult)", lv, got, want)
		}
	}
	for lv, want := range map[int]bool{-1: false, 0: false, 1: true, 2: true, 3: true, 4: true, 5: false, 100: false} {
		if got := rating.ValidLevel(lv); got != want {
			t.Errorf("ValidLevel(%d) = %v, want %v (FR-203: integer 1-4)", lv, got, want)
		}
	}
	if rating.UnratedLevel != 4 || rating.MinLevel != 1 || rating.MaxLevel != 4 {
		t.Errorf("constants = min %d max %d unrated %d, want 1/4/4", rating.MinLevel, rating.MaxLevel, rating.UnratedLevel)
	}
}

// ProfilesAPI.md GET /profiles/age-levels: the ladder is exactly the doc's table.
func TestAC00210_TiersMatchTheAPIDocTableExactly(t *testing.T) {
	want := []rating.Tier{
		{Level: 1, Key: "littleKids", Label: "Little Kids", Movie: []string{"G"}, TV: []string{"TV-Y", "TV-G"}},
		{Level: 2, Key: "olderKids", Label: "Older Kids", Movie: []string{"PG"}, TV: []string{"TV-Y7", "TV-Y7-FV", "TV-PG"}},
		{Level: 3, Key: "teens", Label: "Teens", Movie: []string{"PG-13"}, TV: []string{"TV-14"}},
		{Level: 4, Key: "adult", Label: "Adult", Movie: []string{"R", "NC-17"}, TV: []string{"TV-MA"}},
	}
	if got := rating.Tiers(); !reflect.DeepEqual(got, want) {
		t.Errorf("Tiers() = %+v\nwant     %+v", got, want)
	}
	// Tiers is documented as a deep copy: mutating a result must not change the ladder.
	a := rating.Tiers()
	a[0].Label = "HACKED"
	a[0].Movie[0] = "NC-17"
	a[3].TV[0] = "TV-Y"
	if rating.Level("G") != 1 || rating.Level("TV-MA") != 4 {
		t.Errorf("mutating Tiers() output changed the live ladder: G=%d TV-MA=%d", rating.Level("G"), rating.Level("TV-MA"))
	}
	if b := rating.Tiers(); !reflect.DeepEqual(b, want) {
		t.Errorf("Tiers() after caller mutation = %+v, want unchanged", b)
	}
}

// Every certification the Tiers() listing displays is a certification Level maps to that
// tier: the display table and the mapping cannot disagree (one home, FR-241).
func TestTiersDisplayedCertsMapToTheirOwnTier(t *testing.T) {
	seen := 0
	for _, tier := range rating.Tiers() {
		for _, c := range append(append([]string{}, tier.Movie...), tier.TV...) {
			seen++
			if got := rating.Level(c); got != tier.Level {
				t.Errorf("%s is listed under level %d but Level() = %d", c, tier.Level, got)
			}
		}
	}
	if seen != len(ladderLiterals) {
		t.Errorf("Tiers() lists %d certifications, FR-241 has %d", seen, len(ladderLiterals))
	}
}
