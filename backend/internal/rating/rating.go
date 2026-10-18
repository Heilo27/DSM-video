// Package rating is the one home for the certification → age-level ladder (FRD-002 FR-241)
// and the unrated rule (FR-242). ADR-001 decision 1: it imports nothing from the server, and
// both the Go mapping and the SQL expression are generated from the single table below, so
// they cannot drift. No client parses certification strings; they read the server's ageLevel.
package rating

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"sync/atomic"
)

// Tier is one row of the FR-241 ladder.
type Tier struct {
	Level int
	Key   string
	Label string
	Movie []string
	TV    []string
}

const (
	// MinLevel and MaxLevel bound every profile ceiling and every title level.
	MinLevel = 1
	MaxLevel = 4
	// UnratedLevel is the level of a NULL certification or any string not in the ladder
	// (FR-242: unknown strings fail closed, hidden on every restricted profile).
	UnratedLevel = 4
)

// ladder is FR-241, verbatim. Edit here and nowhere else. A change is a server migration:
// at startup the server compares Fingerprint() with the one it stored and bumps change_seq
// for every item whose level moved (FR-244, cmd/dsvideo-backend/rating_ladder_seq.go).
var ladder = []Tier{
	{Level: 1, Key: "littleKids", Label: "Little Kids", Movie: []string{"G"}, TV: []string{"TV-Y", "TV-G"}},
	{Level: 2, Key: "olderKids", Label: "Older Kids", Movie: []string{"PG"}, TV: []string{"TV-Y7", "TV-Y7-FV", "TV-PG"}},
	{Level: 3, Key: "teens", Label: "Teens", Movie: []string{"PG-13"}, TV: []string{"TV-14"}},
	{Level: 4, Key: "adult", Label: "Adult", Movie: []string{"R", "NC-17"}, TV: []string{"TV-MA"}},
}

// trimSet is the whitespace both Level and SQLLevel strip: space, tab, LF, CR. It matches
// SQLite's TRIM(x, char(32,9,10,13)) byte for byte, which is why it is not unicode.IsSpace.
const trimSet = " \t\n\r"

// table is everything derived from a ladder. It is built once and swapped whole, so a
// reader never sees a mapping from one ladder and a SQL expression from another.
type table struct {
	tiers       []Tier
	levelByCert map[string]int // normalized certification → level
	sqlTail     string         // everything after the column in SQLLevel's CASE expression
}

var current atomic.Pointer[table]

func init() { current.Store(build(ladder)) }

func build(tiers []Tier) *table {
	t := &table{tiers: copyTiers(tiers), levelByCert: make(map[string]int)}
	var b strings.Builder
	b.WriteString(", char(32,9,10,13)))")
	for _, tier := range t.tiers {
		for _, group := range [][]string{tier.Movie, tier.TV} {
			for _, cert := range group {
				norm := normalize(cert)
				if _, dup := t.levelByCert[norm]; dup {
					panic("rating: certification listed twice in the ladder: " + cert)
				}
				t.levelByCert[norm] = tier.Level
				// Ladder strings are constants, but quote defensively anyway.
				fmt.Fprintf(&b, " WHEN '%s' THEN %d", strings.ReplaceAll(norm, "'", "''"), tier.Level)
			}
		}
	}
	fmt.Fprintf(&b, " ELSE %d END)", UnratedLevel)
	t.sqlTail = b.String()
	return t
}

// normalize trims the shared whitespace set and upper-cases ASCII letters only. SQLite's
// built-in UPPER() folds ASCII only, so a Unicode-aware ToUpper here could make Go and SQL
// disagree on some exotic string; this keeps them identical.
func normalize(s string) string {
	s = strings.Trim(s, trimSet)
	buf := []byte(s)
	for i, c := range buf {
		if c >= 'a' && c <= 'z' {
			buf[i] = c - ('a' - 'A')
		}
	}
	return string(buf)
}

// Level maps a raw certification string to its age level. Matching ignores case and
// surrounding whitespace (FR-241); empty or unknown strings are UnratedLevel (FR-242).
func Level(cert string) int {
	if lv, ok := current.Load().levelByCert[normalize(cert)]; ok {
		return lv
	}
	return UnratedLevel
}

// LevelPtr is Level for a nullable column: nil (SQL NULL, the stored form of "unrated",
// FR-240) is UnratedLevel.
func LevelPtr(cert *string) int {
	if cert == nil {
		return UnratedLevel
	}
	return Level(*cert)
}

var identRe = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_.]*$`)

// SQLLevel returns a SQL expression computing the same level as Level from column col.
// NULL falls to the ELSE branch (UnratedLevel). col is spliced into SQL, so it must be a
// plain (optionally table-qualified) identifier written by the programmer; anything else
// panics rather than becoming an injection point.
func SQLLevel(col string) string {
	if !identRe.MatchString(col) {
		panic("rating.SQLLevel: column is not a plain identifier: " + col)
	}
	return "(CASE UPPER(TRIM(" + col + current.Load().sqlTail
}

// Visible returns a WHERE fragment (no leading AND) and its args that keep only titles at
// or below maxLevel. An unrestricted ceiling returns ("", nil): nothing to filter, and the
// CASE expression stays off the query entirely.
func Visible(col string, maxLevel int) (clause string, args []any) {
	if !Restricted(maxLevel) {
		return "", nil
	}
	return SQLLevel(col) + " <= ?", []any{maxLevel}
}

// Restricted reports whether a profile ceiling hides anything (FRD-002 §1: below Adult).
func Restricted(maxLevel int) bool { return maxLevel < MaxLevel }

// ValidLevel reports whether n is a level a profile may hold.
func ValidLevel(n int) bool { return n >= MinLevel && n <= MaxLevel }

// Tiers returns a deep copy of the ladder, for GET /profiles/age-levels (display only).
func Tiers() []Tier { return copyTiers(current.Load().tiers) }

func copyTiers(tiers []Tier) []Tier {
	out := make([]Tier, len(tiers))
	for i, t := range tiers {
		out[i] = Tier{
			Level: t.Level,
			Key:   t.Key,
			Label: t.Label,
			Movie: append([]string(nil), t.Movie...),
			TV:    append([]string(nil), t.TV...),
		}
	}
	return out
}

// ── Ladder versioning (FR-244) ──────────────────────────────────────────────────────────

// Levels is the part of a ladder that decides a title's age level: each normalized
// certification's level, plus the level of everything else. Labels and keys are display
// only and are deliberately left out, so renaming a tier is not a level change.
type Levels struct {
	Unrated int            `json:"unrated"`
	ByCert  map[string]int `json:"levels"`
}

// Level is rating.Level evaluated against this snapshot rather than the live ladder. nil
// is unrated, as with LevelPtr.
func (l Levels) Level(cert *string) int {
	if cert == nil {
		return l.Unrated
	}
	if lv, ok := l.ByCert[normalize(*cert)]; ok {
		return lv
	}
	return l.Unrated
}

// CurrentLevels returns a copy of the live ladder's Levels.
func CurrentLevels() Levels {
	t := current.Load()
	m := make(map[string]int, len(t.levelByCert))
	for k, v := range t.levelByCert {
		m[k] = v
	}
	return Levels{Unrated: UnratedLevel, ByCert: m}
}

// Encode is the canonical text of l. encoding/json writes map keys sorted, so equal
// Levels always encode to identical bytes; Fingerprint hashes exactly this text.
func (l Levels) Encode() string {
	b, err := json.Marshal(l)
	if err != nil { // a map[string]int cannot fail to marshal
		panic("rating: encode levels: " + err.Error())
	}
	return string(b)
}

// Fingerprint is the hex SHA-256 of Encode(): equal exactly when every certification maps
// to the same level and the unrated level is the same.
func (l Levels) Fingerprint() string {
	sum := sha256.Sum256([]byte(l.Encode()))
	return hex.EncodeToString(sum[:])
}

// DecodeLevels parses Encode's output. A snapshot that does not parse, or that names a
// level outside MinLevel..MaxLevel, is an error: the caller cannot tell which titles moved.
func DecodeLevels(s string) (Levels, error) {
	var l Levels
	if err := json.Unmarshal([]byte(s), &l); err != nil {
		return Levels{}, fmt.Errorf("rating: decode levels: %w", err)
	}
	if !ValidLevel(l.Unrated) || l.ByCert == nil {
		return Levels{}, fmt.Errorf("rating: decode levels: missing or invalid fields")
	}
	for cert, lv := range l.ByCert {
		if !ValidLevel(lv) {
			return Levels{}, fmt.Errorf("rating: decode levels: %q has level %d", cert, lv)
		}
	}
	return l, nil
}

// ReplaceLadderForTest swaps the live ladder and returns a func restoring the previous
// one. Tests only: it exists so the server's FR-244 path can be exercised end to end with
// a changed ladder. Production code never calls it; the ladder is a compile-time table.
func ReplaceLadderForTest(tiers []Tier) (restore func()) {
	prev := current.Swap(build(tiers))
	return func() { current.Store(prev) }
}
