package main

// TASK-918 server half: kids' collections (FRD-002 §9, AC-002-60 … AC-002-64, AC-002-66).
// Every test observes the HTTP answer a client gets.

import (
	"fmt"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// colEnv is a family account: an owner, a kid (Older Kids, level 2) and a teen (level 3).
type colEnv struct {
	*qaEnv
	owner, kid, teen string
}

func newColEnv(t *testing.T) *colEnv {
	t.Helper()
	e := newQAEnv(t)
	e.s.cfg.TVPath = "/tv"
	owner, kid := e.pcFamily()
	teen := e.mustCreate(qaAlice, "1234", "Teen", 3, nil)
	return &colEnv{qaEnv: e, owner: owner, kid: kid, teen: teen}
}

func (e *colEnv) tagCompany(itemID, kind string, id int) {
	e.t.Helper()
	if _, err := e.db.Exec(`INSERT INTO item_companies(item_id, kind, company_id, name) VALUES(?,?,?,?)`,
		itemID, kind, id, "n"); err != nil {
		e.t.Fatalf("tag company: %v", err)
	}
}

func (e *colEnv) tagKeyword(itemID string, id int) {
	e.t.Helper()
	if _, err := e.db.Exec(`INSERT INTO item_keywords(item_id, keyword_id, name) VALUES(?,?,?)`, itemID, id, "k"); err != nil {
		e.t.Fatalf("tag keyword: %v", err)
	}
}

// movie seeds a movie with the given genres and certification at a minute offset.
func (e *colEnv) movie(id, genres string, cert *string, minute int) {
	e.t.Helper()
	e.pcTitle(id, "lib_movies", "movie", "/movies/"+id+".mkv", "", genres,
		fmt.Sprintf("2026-01-01T00:%02d:00Z", minute), cert)
}

// episode seeds an episode of show (folder == show) carrying the show's certification.
func (e *colEnv) episode(id, show, genres string, cert *string, minute int) {
	e.t.Helper()
	e.pcTitle(id, "lib_tv", "episode", "/tv/"+show+"/S01/"+id+".mkv", show, genres,
		fmt.Sprintf("2026-01-01T00:%02d:00Z", minute), cert)
}

func (e *colEnv) collections(profile string) []map[string]any {
	e.t.Helper()
	r := e.do(qaAlice, "GET", "/collections", "", profile)
	wantOK(e.t, r, 200)
	raw, _ := r.js["collections"].([]any)
	out := make([]map[string]any, 0, len(raw))
	for _, c := range raw {
		out = append(out, c.(map[string]any))
	}
	return out
}

func collectionIDs(cs []map[string]any) []string {
	ids := make([]string, 0, len(cs))
	for _, c := range cs {
		ids = append(ids, c["id"].(string))
	}
	return ids
}

func (e *colEnv) itemIDs(path, profile string) (ids []string, total int) {
	e.t.Helper()
	r := e.do(qaAlice, "GET", path, "", profile)
	wantOK(e.t, r, 200)
	raw, _ := r.js["items"].([]any)
	for _, it := range raw {
		ids = append(ids, it.(map[string]any)["id"].(string))
	}
	return ids, r.num("total")
}

func (e *colEnv) count_(profile, id string) int {
	e.t.Helper()
	for _, c := range e.collections(profile) {
		if c["id"] == id {
			return int(c["itemCount"].(float64))
		}
	}
	return 0
}

// ── one home (AC-002-66) and the verified ids ───────────────────────────────────────────

func TestAC00266_DefinitionsHaveOneHomeAndEveryCompanyNamesItsKind(t *testing.T) {
	seen := map[string]bool{}
	for _, d := range collectionDefs {
		if seen[d.ID] {
			t.Errorf("duplicate collection id %q", d.ID)
		}
		seen[d.ID] = true
		for _, c := range d.Companies {
			if c.Kind != tagKindCompany && c.Kind != tagKindNetwork {
				t.Errorf("%s: company %d has kind %q: an id without its kind is ambiguous (FR-271)", d.ID, c.ID, c.Kind)
			}
		}
	}

	// The ids Ryan's collections rest on, as checked on themoviedb.org 2026-10-17. A wrong id
	// fails silently (the collection is just empty), so any edit has to touch this too.
	want := map[string]struct {
		companies []companyRef
		keywords  []int
	}{
		"pixar":        {companies: []companyRef{{"company", 3}}},
		"disney":       {companies: []companyRef{{"company", 2}, {"company", 6125}, {"company", 3166}}},
		"dreamworks":   {companies: []companyRef{{"company", 521}}},
		"illumination": {companies: []companyRef{{"company", 6704}}},
		"holiday":      {keywords: []int{207317}},
		"halloween":    {keywords: []int{3335}},
	}
	for id, w := range want {
		var got *collectionDef
		for i := range collectionDefs {
			if collectionDefs[i].ID == id {
				got = &collectionDefs[i]
			}
		}
		if got == nil {
			t.Errorf("collection %q is not defined", id)
			continue
		}
		if fmt.Sprint(got.Companies) != fmt.Sprint(w.companies) || fmt.Sprint(got.Keywords) != fmt.Sprint(w.keywords) {
			t.Errorf("%s rule = companies %v keywords %v, want companies %v keywords %v", id, got.Companies, got.Keywords, w.companies, w.keywords)
		}
	}
}

func TestAC00266_NoOtherSourceFileRestatesACollectionRule(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range files {
		if f == "collections.go" || strings.HasSuffix(f, "_test.go") {
			continue
		}
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		src := string(b)
		for _, needle := range []string{"207317", "3335", `"dreamworks"`, `"halloween"`, `"illumination"`} {
			if strings.Contains(src, needle) {
				t.Errorf("%s restates %s: collection rules live only in collections.go (AC-002-66)", f, needle)
			}
		}
	}
}

// ── membership (AC-002-61), including the company-vs-network trap ───────────────────────

func TestAC00261_MembershipFollowsCompanyKeywordAndGenreRules(t *testing.T) {
	e := newColEnv(t)
	e.movie("m_pixar", "Animation", sp("G"), 1)
	e.tagCompany("m_pixar", "company", 3)
	e.episode("e_abc", "ABCShow", "Drama", sp("TV-PG"), 2)
	e.tagCompany("e_abc", "network", 2) // network 2 is ABC, NOT Walt Disney Pictures
	e.movie("m_xmas", "Comedy", sp("G"), 3)
	e.tagKeyword("m_xmas", 207317)
	e.movie("m_hallow", "Comedy", sp("PG"), 4)
	e.tagKeyword("m_hallow", 3335)
	e.episode("e_kids", "KidsShow", "Kids", sp("TV-Y"), 5)

	in := func(col string) []string {
		ids, _ := e.itemIDs("/collections/"+col+"/items", e.kid)
		return ids
	}
	if got := in("pixar"); fmt.Sprint(got) != "[m_pixar]" {
		t.Errorf("pixar = %v, want [m_pixar]", got)
	}
	if got := in("disney"); len(got) != 0 {
		t.Errorf("disney = %v, want none: network 2 (ABC) is not company 2 (Walt Disney Pictures)", got)
	}
	if got := in("holiday"); fmt.Sprint(got) != "[m_xmas]" {
		t.Errorf("holiday = %v, want [m_xmas]", got)
	}
	if got := in("halloween"); fmt.Sprint(got) != "[m_hallow]" {
		t.Errorf("halloween = %v, want [m_hallow]", got)
	}
	if got := in("family"); fmt.Sprint(got) != "[e_kids]" {
		t.Errorf("family = %v, want [e_kids] (genre \"Kids\")", got)
	}
	// The ABC show is in no collection at all.
	for _, c := range e.collections(e.kid) {
		ids, _ := e.itemIDs("/collections/"+c["id"].(string)+"/items", e.kid)
		for _, id := range ids {
			if id == "e_abc" {
				t.Errorf("ABC show (network 2) landed in %s", c["id"])
			}
		}
	}
}

func TestAC00261_KindIsHonouredInBothDirections(t *testing.T) {
	e := newColEnv(t)
	// Walt Disney Pictures as a company is Disney; the same number as a network is not.
	e.movie("m_company2", "Drama", sp("G"), 1)
	e.tagCompany("m_company2", "company", 2)
	e.movie("m_network2", "Drama", sp("G"), 2)
	e.tagCompany("m_network2", "network", 2)
	// Company 3 is Pixar; network 3 is a different thing and must not match Pixar.
	e.movie("m_network3", "Drama", sp("G"), 3)
	e.tagCompany("m_network3", "network", 3)

	if ids, _ := e.itemIDs("/collections/disney/items", e.kid); fmt.Sprint(ids) != "[m_company2]" {
		t.Errorf("disney = %v, want only the company-2 title", ids)
	}
	if ids, _ := e.itemIDs("/collections/pixar/items", e.kid); len(ids) != 0 {
		t.Errorf("pixar = %v, want none: network 3 is not company 3", ids)
	}
}

func TestAC00261_AllThreeDisneyCompaniesAndTheOtherStudiosMatch(t *testing.T) {
	e := newColEnv(t)
	for i, c := range []struct {
		id  string
		co  int
		col string
	}{
		{"d_pictures", 2, "disney"}, {"d_animation", 6125, "disney"}, {"d_productions", 3166, "disney"},
		{"dw", 521, "dreamworks"}, {"ill", 6704, "illumination"},
	} {
		e.movie(c.id, "Animation", sp("G"), i)
		e.tagCompany(c.id, "company", c.co)
	}
	if ids, total := e.itemIDs("/collections/disney/items", e.kid); total != 3 || len(ids) != 3 {
		t.Errorf("disney = %v (total %d), want its three company ids", ids, total)
	}
	if ids, _ := e.itemIDs("/collections/dreamworks/items", e.kid); fmt.Sprint(ids) != "[dw]" {
		t.Errorf("dreamworks = %v", ids)
	}
	if ids, _ := e.itemIDs("/collections/illumination/items", e.kid); fmt.Sprint(ids) != "[ill]" {
		t.Errorf("illumination = %v", ids)
	}
}

func TestAC00261_GenreMatchIsExactNotSubstring(t *testing.T) {
	e := newColEnv(t)
	e.movie("m_famdrama", "Family Drama", sp("G"), 1) // a genre that merely contains "Family"
	e.movie("m_fam", "Drama, Family", sp("G"), 2)     // TMDb's comma-space joined list
	e.movie("m_anim", "Animation,Comedy", sp("G"), 3)
	if ids, _ := e.itemIDs("/collections/family/items", e.kid); fmt.Sprint(ids) != "[m_fam]" {
		t.Errorf("family = %v, want [m_fam] only", ids)
	}
	if ids, _ := e.itemIDs("/collections/animation/items", e.kid); fmt.Sprint(ids) != "[m_anim]" {
		t.Errorf("animation = %v, want [m_anim]", ids)
	}
}

// ── tiers and emptiness (AC-002-60) ─────────────────────────────────────────────────────

func TestAC00260_KidsGetEveryNonEmptyCollectionInDefinitionOrder(t *testing.T) {
	e := newColEnv(t)
	// Seed so that "family" and "pixar" and "animation" are non-empty, others empty. Insert
	// out of definition order to prove the order is the definition's.
	e.movie("m_fam", "Family", sp("G"), 1)
	e.movie("m_pixar", "Animation", sp("G"), 2)
	e.tagCompany("m_pixar", "company", 3)

	got := collectionIDs(e.collections(e.kid))
	if want := "[pixar animation family]"; fmt.Sprint(got) != want {
		t.Errorf("kid collections = %v, want %s: non-empty only, definition order, genre kinds included", got, want)
	}
	for _, c := range e.collections(e.kid) {
		if c["id"] == "pixar" && (c["title"] != "Pixar" || c["kind"] != "studio") {
			t.Errorf("pixar payload = %v", c)
		}
	}
}

func TestAC00260_TeensAndAdultsGetOnlyTheAllAudienceCollections(t *testing.T) {
	e := newColEnv(t)
	e.movie("m_fam", "Family,Animation", sp("G"), 1) // would fill animation and family
	e.movie("m_pixar", "Animation", sp("PG"), 2)
	e.tagCompany("m_pixar", "company", 3)
	e.movie("m_xmas", "Comedy", sp("PG-13"), 3)
	e.tagKeyword("m_xmas", 207317)

	for name, profile := range map[string]string{"teen": e.teen, "owner": e.owner} {
		got := collectionIDs(e.collections(profile))
		if want := "[pixar holiday]"; fmt.Sprint(got) != want {
			t.Errorf("%s collections = %v, want %s: no kids-audience genre collections (FR-274)", name, got, want)
		}
	}
	// And the kid still has the genre ones.
	if got := collectionIDs(e.collections(e.kid)); fmt.Sprint(got) != "[pixar animation family]" {
		t.Errorf("kid collections = %v", got)
	}
}

func TestAC00260_NothingTaggedMeansAnEmptyListNotAnError(t *testing.T) {
	e := newColEnv(t) // FR-276: no TMDb key, no tags, no genres
	r := e.do(qaAlice, "GET", "/collections", "", e.kid)
	wantOK(t, r, 200)
	raw, present := r.js["collections"].([]any)
	if !present || len(raw) != 0 {
		t.Errorf("collections = %v (present %v), want an empty array", r.js["collections"], present)
	}
}

func TestAC00260_ACollectionOnlyTheCeilingEmptiesIsHidden(t *testing.T) {
	e := newColEnv(t)
	e.movie("m_r", "Comedy", sp("R"), 1)
	e.tagKeyword("m_r", 3335)
	if got := collectionIDs(e.collections(e.kid)); len(got) != 0 {
		t.Errorf("kid collections = %v, want none: halloween holds only an R title (FR-273)", got)
	}
	if got := collectionIDs(e.collections(e.owner)); fmt.Sprint(got) != "[halloween]" {
		t.Errorf("owner collections = %v, want [halloween]", got)
	}
}

// ── the ceiling inside every collection (AC-002-62) ─────────────────────────────────────

func TestAC00262_ARatedDisneyTitleIsNeitherReturnedNorCountedForAKid(t *testing.T) {
	e := newColEnv(t)
	e.movie("m_g", "Family", sp("G"), 1)
	e.tagCompany("m_g", "company", 2)
	e.movie("m_r", "Drama", sp("R"), 2)
	e.tagCompany("m_r", "company", 2)
	e.movie("m_unrated", "Drama", nil, 3) // unrated is level 4 (FR-242)
	e.tagCompany("m_unrated", "company", 2)

	ids, total := e.itemIDs("/collections/disney/items", e.kid)
	if fmt.Sprint(ids) != "[m_g]" || total != 1 {
		t.Errorf("kid disney = %v (total %d), want [m_g] total 1", ids, total)
	}
	if n := e.count_(e.kid, "disney"); n != 1 {
		t.Errorf("kid disney itemCount = %d, want 1", n)
	}
	if ids, total := e.itemIDs("/collections/disney/items", e.owner); len(ids) != 3 || total != 3 {
		t.Errorf("owner disney = %v (total %d), want all three", ids, total)
	}
	if n := e.count_(e.owner, "disney"); n != 3 {
		t.Errorf("owner disney itemCount = %d, want 3", n)
	}
	// The teen sits between: PG-13 is theirs, R is not.
	e.movie("m_pg13", "Drama", sp("PG-13"), 4)
	e.tagCompany("m_pg13", "company", 2)
	if n := e.count_(e.teen, "disney"); n != 2 {
		t.Errorf("teen disney itemCount = %d, want 2 (G + PG-13)", n)
	}
}

func TestAC00262_CeilingIsAppliedBeforePagingNotAfter(t *testing.T) {
	e := newColEnv(t)
	// 30 newer R titles in the collection, 3 older G titles. A page cut before filtering
	// would hand the kid an empty first page.
	for i := 0; i < 30; i++ {
		id := fmt.Sprintf("r%02d", i)
		e.movie(id, "Drama", sp("R"), 30+i)
		e.tagCompany(id, "company", 3)
	}
	for i := 0; i < 3; i++ {
		id := fmt.Sprintf("g%d", i)
		e.movie(id, "Drama", sp("G"), i)
		e.tagCompany(id, "company", 3)
	}
	ids, total := e.itemIDs("/collections/pixar/items?sort=addedAt&limit=2&offset=0", e.kid)
	if total != 3 || len(ids) != 2 {
		t.Fatalf("page 1 = %v total %d, want 2 of 3", ids, total)
	}
	ids2, total2 := e.itemIDs("/collections/pixar/items?sort=addedAt&limit=2&offset=2", e.kid)
	if total2 != 3 || len(ids2) != 1 {
		t.Errorf("page 2 = %v total %d, want 1 of 3", ids2, total2)
	}
	if got := fmt.Sprint(append(ids, ids2...)); got != "[g2 g1 g0]" {
		t.Errorf("addedAt order across pages = %s, want newest first [g2 g1 g0]", got)
	}
	if past, total := e.itemIDs("/collections/pixar/items?offset=99", e.kid); len(past) != 0 || total != 3 {
		t.Errorf("offset past the end = %v total %d, want none of 3", past, total)
	}
}

// ── shows once (AC-002-63) ──────────────────────────────────────────────────────────────

func TestAC00263_AShowIsListedOnceAndCountedOnceNeverPerEpisode(t *testing.T) {
	e := newColEnv(t)
	for i := 1; i <= 4; i++ {
		id := fmt.Sprintf("bluey%d", i)
		e.episode(id, "Bluey", "Animation,Family", sp("TV-Y"), i)
		e.tagCompany(id, "network", 7)
		e.tagKeyword(id, 207317) // every episode carries the show's tags
	}
	e.movie("m_xmas", "Comedy", sp("G"), 9)
	e.tagKeyword("m_xmas", 207317)

	r := e.do(qaAlice, "GET", "/collections/holiday/items", "", e.kid)
	wantOK(t, r, 200)
	if r.num("total") != 2 {
		t.Errorf("holiday total = %d, want 2 (one show + one movie, not 5 rows)", r.num("total"))
	}
	var shows int
	for _, it := range r.js["items"].([]any) {
		m := it.(map[string]any)
		if m["type"] == "episode" {
			shows++
			if m["title"] != "Bluey" || m["showName"] != "Bluey" {
				t.Errorf("show entry title/showName = %v/%v, want Bluey", m["title"], m["showName"])
			}
		}
	}
	if shows != 1 {
		t.Errorf("%d show entries, want exactly 1", shows)
	}
	if n := e.count_(e.kid, "holiday"); n != 2 {
		t.Errorf("holiday itemCount = %d, want 2", n)
	}
	if n := e.count_(e.kid, "animation"); n != 1 {
		t.Errorf("animation itemCount = %d, want 1 (the show once)", n)
	}
}

func TestAC00263_AShowAboveTheCeilingIsHiddenWithAllItsEpisodes(t *testing.T) {
	e := newColEnv(t)
	for i := 1; i <= 3; i++ {
		id := fmt.Sprintf("adult%d", i)
		e.episode(id, "AdultToon", "Animation", sp("TV-MA"), i)
	}
	if n := e.count_(e.kid, "animation"); n != 0 {
		t.Errorf("kid animation itemCount = %d, want 0", n)
	}
	if n := e.count_(e.teen, "animation"); n != 0 {
		t.Errorf("teen animation = %d (not offered to teens)", n)
	}
}

// ── unknown / hidden ids (AC-002-64) ────────────────────────────────────────────────────

func TestAC00264_UndefinedOrNotOfferedCollectionIs404UnknownCollection(t *testing.T) {
	e := newColEnv(t)
	e.movie("m_anim", "Animation", sp("G"), 1)

	for _, tc := range []struct{ name, id, profile string }{
		{"undefined id", "marvel", e.kid},
		{"undefined id, owner", "marvel", e.owner},
		{"kids-audience collection, teen", "animation", e.teen},
		{"kids-audience collection, owner", "family", e.owner},
		{"case differs", "Pixar", e.kid},
	} {
		r := e.do(qaAlice, "GET", "/collections/"+tc.id+"/items", "", tc.profile)
		if r.code != 404 || r.str("error") != "unknown_collection" {
			t.Errorf("%s: %d %s, want 404 unknown_collection", tc.name, r.code, r.raw)
		}
	}
	// The same id answers for the kid, who is offered it.
	if ids, _ := e.itemIDs("/collections/animation/items", e.kid); fmt.Sprint(ids) != "[m_anim]" {
		t.Errorf("kid animation = %v", ids)
	}
}

func TestFR275_AnOfferedCollectionWithNoVisibleTitlesIs200Empty(t *testing.T) {
	e := newColEnv(t)
	r := e.do(qaAlice, "GET", "/collections/pixar/items", "", e.kid)
	wantOK(t, r, 200)
	if items, ok := r.js["items"].([]any); !ok || len(items) != 0 || r.num("total") != 0 {
		t.Errorf("empty offered collection = %s, want {total:0, items:[]}", r.raw)
	}
}

// ── payload and sorting ─────────────────────────────────────────────────────────────────

func TestFR275_ItemsCarryTheItemFieldsAndPosterIsTheNewestMembersArtwork(t *testing.T) {
	e := newColEnv(t)
	e.movie("old", "Family", sp("G"), 1)
	e.movie("new", "Family", sp("PG"), 2)
	e.movie("newest_no_art", "Family", sp("G"), 3)
	for _, id := range []string{"old", "new"} {
		if _, err := e.db.Exec(`UPDATE items SET poster_path='/p.jpg' WHERE id=?`, id); err != nil {
			t.Fatal(err)
		}
	}
	r := e.do(qaAlice, "GET", "/collections/family/items?sort=title", "", e.kid)
	wantOK(t, r, 200)
	for _, it := range r.js["items"].([]any) {
		m := it.(map[string]any)
		if m["id"] == "new" && (m["contentRating"] != "PG" || m["ageLevel"] != float64(2) || m["posterImageId"] != "new") {
			t.Errorf("item fields = %v, want contentRating PG, ageLevel 2, posterImageId new", m)
		}
	}
	for _, c := range e.collections(e.kid) {
		if c["id"] == "family" && c["posterImageId"] != "new" {
			t.Errorf("family posterImageId = %v, want new (newest member that has a poster)", c["posterImageId"])
		}
	}
}

func TestFR275_SortKeysAndOrder(t *testing.T) {
	e := newColEnv(t)
	for i, m := range []struct {
		id   string
		year int
	}{{"b_2005", 2005}, {"a_2015", 2015}, {"c_1995", 1995}} {
		e.movie(m.id, "Family", sp("G"), i)
		if _, err := e.db.Exec(`UPDATE items SET year=?, rating=? WHERE id=?`, m.year, float64(i), m.id); err != nil {
			t.Fatal(err)
		}
	}
	e.movie("d_noyear", "Family", sp("G"), 9)

	for _, tc := range []struct{ query, want string }{
		{"", "[a_2015 b_2005 c_1995 d_noyear]"}, // title ascending by default
		{"?sort=title&order=desc", "[d_noyear c_1995 b_2005 a_2015]"},
		{"?sort=year", "[a_2015 b_2005 c_1995 d_noyear]"},           // newest first, missing last
		{"?sort=year&order=asc", "[c_1995 b_2005 a_2015 d_noyear]"}, // missing last either way
		{"?sort=addedAt", "[d_noyear c_1995 a_2015 b_2005]"},
		{"?sort=rating", "[c_1995 a_2015 b_2005 d_noyear]"},
		{"?sort=bogus&order=sideways", "[a_2015 b_2005 c_1995 d_noyear]"}, // unknown values fall back
	} {
		ids, _ := e.itemIDs("/collections/family/items"+tc.query, e.kid)
		if got := fmt.Sprint(ids); got != tc.want {
			t.Errorf("query %q = %s, want %s", tc.query, got, tc.want)
		}
	}
}

func TestFR275_CollectionRoutesNeedASession(t *testing.T) {
	e := newColEnv(t)
	for _, path := range []string{"/collections", "/collections/pixar/items"} {
		rec := httptest.NewRecorder()
		e.h.ServeHTTP(rec, httptest.NewRequest("GET", path, nil))
		if rec.Code != 401 {
			t.Errorf("GET %s without a token = %d, want 401", path, rec.Code)
		}
	}
}
