package main

// TASK-970: the low-priority FRD-002 collection oracle assertions (OC-2199, OC-2201, OC-2204,
// OC-2212, OC-2213 tie-break). Each test observes the HTTP answer a client gets and carries
// literal expected values only. The mutation each one answers to is named in its comment.

import (
	"fmt"
	"testing"
)

// OC-2199. given: a title tagged only with keyword 65 (holiday). when: the holiday collection
// is read. then: it is not a member. A control title carrying the real keyword (207317) proves
// the collection is not simply empty. Red if keyword 65 is added to the holiday definition.
func TestOC2199_KeywordHolidaySixtyFiveIsNotAHolidayMember(t *testing.T) {
	e := newColEnv(t)
	e.movie("m_vacation", "Comedy", sp("G"), 1)
	e.tagKeyword("m_vacation", 65)
	e.movie("m_xmas", "Comedy", sp("G"), 2)
	e.tagKeyword("m_xmas", 207317)

	ids, total := e.itemIDs("/collections/holiday/items", e.kid)
	if fmt.Sprint(ids) != "[m_xmas]" || total != 1 {
		t.Errorf("holiday = %v total %d, want [m_xmas] total 1: keyword 65 tags vacation films, not holidays", ids, total)
	}
	if n := e.count_(e.kid, "holiday"); n != 1 {
		t.Errorf("holiday itemCount = %d, want 1", n)
	}
}

// OC-2201. given: one show (three episodes) in a collection. when: its entry is inspected.
// then: an episode-typed item whose title and showName are the show's name, year the EARLIEST
// across episodes, addedAt the NEWEST; and the show opens by showName. Red if the year
// aggregation takes the latest, or addedAt the earliest, or the entry stops being episode-typed.
func TestOC2201_ShowEntryAggregatesYearEarliestAddedAtNewestAndOpensByName(t *testing.T) {
	e := newColEnv(t)
	minutes := []int{1, 5, 3}
	for i, y := range []int{2010, 2008, 2012} {
		id := fmt.Sprintf("bluey%d", i+1)
		e.episode(id, "Bluey", "Animation,Family", sp("TV-Y"), minutes[i])
		e.tagKeyword(id, 207317)
		if _, err := e.db.Exec(`UPDATE items SET year=? WHERE id=?`, y, id); err != nil {
			t.Fatal(err)
		}
	}
	// a movie in the same collection, to prove the show is not simply the only row
	e.movie("m_xmas", "Comedy", sp("G"), 9)
	e.tagKeyword("m_xmas", 207317)

	r := e.do(qaAlice, "GET", "/collections/holiday/items", "", e.kid)
	wantOK(t, r, 200)
	var entries []map[string]any
	for _, it := range r.js["items"].([]any) {
		if m := it.(map[string]any); m["type"] == "episode" {
			entries = append(entries, m)
		}
	}
	if len(entries) != 1 {
		t.Fatalf("%d episode entries, want exactly 1 for the show", len(entries))
	}
	m := entries[0]
	if m["title"] != "Bluey" || m["showName"] != "Bluey" {
		t.Errorf("title/showName = %v/%v, want Bluey/Bluey", m["title"], m["showName"])
	}
	if m["year"] != float64(2008) {
		t.Errorf("year = %v, want 2008 (earliest of 2010, 2008, 2012)", m["year"])
	}
	if m["addedAt"] != "2026-01-01T00:05:00Z" {
		t.Errorf("addedAt = %v, want 2026-01-01T00:05:00Z (newest of minutes 1, 5, 3)", m["addedAt"])
	}

	// opening by showName: the show detail answers for the kid, with all three episodes.
	d := e.do(qaAlice, "GET", "/shows/Bluey", "", e.kid)
	wantOK(t, d, 200)
	seasons, _ := d.js["seasons"].([]any)
	var eps []string
	for _, s := range seasons {
		for _, ep := range s.(map[string]any)["episodes"].([]any) {
			eps = append(eps, ep.(map[string]any)["id"].(string))
		}
	}
	if d.str("title") != "Bluey" || fmt.Sprint(eps) != "[bluey1 bluey2 bluey3]" {
		t.Errorf("GET /shows/Bluey title %q episodes %v, want Bluey [bluey1 bluey2 bluey3]; body %s", d.str("title"), eps, d.raw)
	}
}

// OC-2204. given: a kids' profile and a visible member for every collection. when: GET
// /collections. then: exactly 8 entries, in the stated order, with the stated titles and
// kinds (studio x4, theme x2, genre x2). Red if an entry is dropped, reordered, retitled or
// re-kinded.
func TestOC2204_KidsGetExactlyTheEightCollectionsWithTitlesAndKinds(t *testing.T) {
	e := newColEnv(t)
	e.movie("m_pixar", "Drama", sp("G"), 1)
	e.tagCompany("m_pixar", "company", 3)
	e.movie("m_disney", "Drama", sp("G"), 2)
	e.tagCompany("m_disney", "company", 2)
	e.movie("m_dw", "Drama", sp("G"), 3)
	e.tagCompany("m_dw", "company", 521)
	e.movie("m_illum", "Drama", sp("G"), 4)
	e.tagCompany("m_illum", "company", 6704)
	e.movie("m_xmas", "Drama", sp("G"), 5)
	e.tagKeyword("m_xmas", 207317)
	e.movie("m_hallow", "Drama", sp("G"), 6)
	e.tagKeyword("m_hallow", 3335)
	e.movie("m_anim", "Animation", sp("G"), 7)
	e.movie("m_fam", "Family", sp("G"), 8)

	var got []string
	kinds := map[string]int{}
	for _, c := range e.collections(e.kid) {
		got = append(got, fmt.Sprintf("%v=%v/%v", c["id"], c["title"], c["kind"]))
		kinds[c["kind"].(string)]++
	}
	want := "[pixar=Pixar/studio disney=Disney/studio dreamworks=DreamWorks/studio illumination=Illumination/studio " +
		"holiday=Holiday/theme halloween=Halloween/theme animation=Animation/genre family=Family/genre]"
	if fmt.Sprint(got) != want {
		t.Errorf("kid collections =\n  %v\nwant\n  %s", got, want)
	}
	if kinds["studio"] != 4 || kinds["theme"] != 2 || kinds["genre"] != 2 {
		t.Errorf("kinds = %v, want studio 4, theme 2, genre 2", kinds)
	}
}

// OC-2212. given: a kids' profile and a collection with more members than one page (plus a
// member above the ceiling). when: paged with a small limit. then: total equals the visible
// count, the union of pages is the visible set with each id once, and every item carries
// contentRating, ageLevel and libraryId and NO progress. Red if the ceiling is applied after
// paging, if a page repeats or drops a member, or if progress leaks into a collection item.
func TestOC2212_PagesUnionToTheVisibleSetAndItemsCarryRatingAndLibraryButNoProgress(t *testing.T) {
	e := newColEnv(t)
	visible := []string{"f1", "f2", "f3", "f4", "f5", "f6", "f7"}
	for i, id := range visible {
		e.movie(id, "Family", sp("PG"), i+1)
	}
	e.movie("f_hidden_r", "Family", sp("R"), 20) // above the Older Kids ceiling: never visible
	// the kid has progress on f1: a collection item must still not carry it
	wantOK(t, e.do(qaAlice, "POST", "/items/f1/progress", `{"positionSeconds":120,"durationSeconds":600}`, e.kid), 200)

	seen := map[string]int{}
	for off := 0; off < 8; off += 3 {
		r := e.do(qaAlice, "GET", fmt.Sprintf("/collections/family/items?sort=title&limit=3&offset=%d", off), "", e.kid)
		wantOK(t, r, 200)
		if r.num("total") != 7 {
			t.Errorf("offset %d total = %d, want 7 (visible members only)", off, r.num("total"))
		}
		for _, it := range r.js["items"].([]any) {
			m := it.(map[string]any)
			seen[m["id"].(string)]++
			if m["contentRating"] != "PG" || m["ageLevel"] != float64(2) || m["libraryId"] != "lib_movies" {
				t.Errorf("%v fields contentRating/ageLevel/libraryId = %v/%v/%v, want PG/2/lib_movies",
					m["id"], m["contentRating"], m["ageLevel"], m["libraryId"])
			}
			for _, banned := range []string{"progress", "positionSeconds", "progressSeconds", "resumePositionSeconds"} {
				if _, has := m[banned]; has {
					t.Errorf("%v carries %q: collection items must not carry progress", m["id"], banned)
				}
			}
		}
	}
	if len(seen) != 7 {
		t.Errorf("union of pages = %v, want the 7 visible ids", seen)
	}
	for _, id := range visible {
		if seen[id] != 1 {
			t.Errorf("%s appeared %d times across pages, want exactly 1", id, seen[id])
		}
	}
	if seen["f_hidden_r"] != 0 {
		t.Errorf("above-ceiling member f_hidden_r leaked into a page")
	}
}

// OC-2213 tie-break. given: members that tie on the sort key. when: sorted. then: ties break
// on title (case-insensitive), then on id. Red if the title tie-break is removed or the id
// tie-break is removed. Row c_3 is renamed z_c AFTER seeding so its path ("/movies/c_3.mkv",
// which the query orders by) sorts first among the equal titles while its id sorts last: path
// order cannot satisfy the assertion by accident.
func TestOC2213_TiesBreakOnTitleThenId(t *testing.T) {
	e := newColEnv(t)
	for _, m := range []struct{ id, title string }{
		{"a_1", "Zebra"}, {"b_2", "apple"}, {"c_3", "Mango"}, {"d_4", "Mango"}, {"e_5", "Mango"},
	} {
		e.movie(m.id, "Family", sp("G"), 1) // same addedAt for all: ties on addedAt
		if _, err := e.db.Exec(`UPDATE items SET title=?, year=2000, rating=5.0 WHERE id=?`, m.title, m.id); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := e.db.Exec(`UPDATE items SET id='z_c' WHERE id='c_3'`); err != nil {
		t.Fatal(err)
	}
	// every sort key ties across all five rows: result must be title (case-insensitive), then id
	const want = "[b_2 d_4 e_5 z_c a_1]"
	for _, q := range []string{"?sort=year", "?sort=rating", "?sort=addedAt", "?sort=year&order=asc", "?sort=addedAt&order=asc"} {
		ids, _ := e.itemIDs("/collections/family/items"+q, e.kid)
		if got := fmt.Sprint(ids); got != want {
			t.Errorf("query %q = %s, want %s (apple, Mango d_4/e_5/z_c, Zebra)", q, got, want)
		}
	}
}
