package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"dsvideo/backend/internal/metadata"
	agerating "dsvideo/backend/internal/rating"

	"github.com/go-chi/chi/v5"
)

// TASK-747 FR-150 cast photos: item_cast storage, the castMembers detail field, the cast image
// route, the image-cache cap setting and the scope=cast backfill. They run the production
// schema (migrate), handlers and TMDb client, against a local fake of TMDb.

// ---- helpers ----

func castRows(t *testing.T, s *Server, itemID string) []metadata.CastMember {
	t.Helper()
	rows, err := s.db.Query(`SELECT tmdb_person_id, name, character, profile_path FROM item_cast WHERE item_id = ? ORDER BY ordinal`, itemID)
	if err != nil {
		t.Fatalf("query item_cast: %v", err)
	}
	defer rows.Close()
	var out []metadata.CastMember
	for rows.Next() {
		var m metadata.CastMember
		if err := rows.Scan(&m.ID, &m.Name, &m.Character, &m.ProfilePath); err != nil {
			t.Fatalf("scan: %v", err)
		}
		out = append(out, m)
	}
	return out
}

func storeCast(t *testing.T, s *Server, itemID string, members []metadata.CastMember) {
	t.Helper()
	tx, err := s.db.Begin()
	if err != nil {
		t.Fatal(err)
	}
	if err := replaceItemCast(context.Background(), tx, itemID, members); err != nil {
		tx.Rollback()
		t.Fatalf("replaceItemCast: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
}

func hasTable(t *testing.T, db *sql.DB, name string) bool {
	t.Helper()
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?`, name).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n == 1
}

func columnsOf(t *testing.T, db *sql.DB, table string) []string {
	t.Helper()
	rows, err := db.Query(`SELECT name FROM pragma_table_info(?) ORDER BY cid`, table)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var cols []string
	for rows.Next() {
		var c string
		if err := rows.Scan(&c); err != nil {
			t.Fatal(err)
		}
		cols = append(cols, c)
	}
	return cols
}

func detailJSON(t *testing.T, s *Server, id string) map[string]any {
	t.Helper()
	rctx := chi.NewRouteContext()
	rctx.URLParams.Add("id", id)
	req := httptest.NewRequest(http.MethodGet, "/items/"+id, nil)
	req = req.WithContext(context.WithValue(req.Context(), chi.RouteCtxKey, rctx))
	req = req.WithContext(context.WithValue(req.Context(), viewerKey, viewer{
		UserID: "u1", ProfileID: "p1", MaxAgeLevel: agerating.MaxLevel, IsOwner: true}))
	rec := httptest.NewRecorder()
	s.handleItemDetail(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET %s: %d %s", id, rec.Code, rec.Body.String())
	}
	var out map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	return out
}

func setCastNames(t *testing.T, s *Server, id, names string) {
	t.Helper()
	if _, err := s.db.Exec(`UPDATE items SET cast_names = ? WHERE id = ?`, names, id); err != nil {
		t.Fatal(err)
	}
}

// ---- migration ----

func TestMigrateCreatesItemCastOnANewDB(t *testing.T) {
	s := newBackfillServer(t, nil)
	if !hasTable(t, s.db, "item_cast") || !hasTable(t, s.db, "cast_backfill_empty") {
		t.Fatalf("migrate on a fresh DB did not create item_cast / cast_backfill_empty")
	}
	want := []string{"item_id", "ordinal", "tmdb_person_id", "name", "character", "profile_path"}
	if got := columnsOf(t, s.db, "item_cast"); !reflect.DeepEqual(got, want) {
		t.Errorf("item_cast columns = %v, want %v", got, want)
	}
	if err := migrate(s.db); err != nil {
		t.Errorf("second migrate (idempotent) failed: %v", err)
	}
}

func TestMigrateAddsItemCastToAnOldDBWithoutTouchingItsRows(t *testing.T) {
	s := newBackfillServer(t, nil)
	insertItem(t, s, itemFixture{id: "m1", typ: "movie", title: "Old Title", tmdbID: 5, enriched: true})
	setCastNames(t, s, "m1", "Ann,Bob")
	// An old database: everything but the cast tables.
	for _, tbl := range []string{"item_cast", "cast_backfill_empty"} {
		if _, err := s.db.Exec(`DROP TABLE ` + tbl); err != nil {
			t.Fatalf("drop %s: %v", tbl, err)
		}
	}
	if err := migrate(s.db); err != nil {
		t.Fatalf("migrate old DB: %v", err)
	}
	if !hasTable(t, s.db, "item_cast") || !hasTable(t, s.db, "cast_backfill_empty") {
		t.Fatalf("migrate did not add the cast tables to an old DB")
	}
	var title, names string
	if err := s.db.QueryRow(`SELECT title, cast_names FROM items WHERE id='m1'`).Scan(&title, &names); err != nil {
		t.Fatal(err)
	}
	if title != "Old Title" || names != "Ann,Bob" {
		t.Errorf("existing row changed by the migration: %q %q", title, names)
	}
	storeCast(t, s, "m1", []metadata.CastMember{{ID: 1, Name: "Ann"}})
	if got := len(castRows(t, s, "m1")); got != 1 {
		t.Errorf("rows after migrate+store = %d, want 1", got)
	}
}

// ---- replaceItemCast ----

func TestReplaceItemCastReplacesRatherThanAppends(t *testing.T) {
	s := newBackfillServer(t, nil)
	storeCast(t, s, "m1", []metadata.CastMember{
		{ID: 1, Name: "Old One", Character: "A"}, {ID: 2, Name: "Old Two"}, {ID: 3, Name: "Old Three"}})
	storeCast(t, s, "m2", []metadata.CastMember{{ID: 9, Name: "Other Title"}})
	storeCast(t, s, "m1", []metadata.CastMember{{ID: 4, Name: "New One", Character: "B", ProfilePath: "/n.jpg"}})

	got := castRows(t, s, "m1")
	want := []metadata.CastMember{{ID: 4, Name: "New One", Character: "B", ProfilePath: "/n.jpg"}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("m1 cast = %+v, want exactly %+v", got, want)
	}
	if n := len(castRows(t, s, "m2")); n != 1 {
		t.Errorf("m2 cast rows = %d, want 1 (another title must be untouched)", n)
	}
	storeCast(t, s, "m1", nil)
	if n := len(castRows(t, s, "m1")); n != 0 {
		t.Errorf("replace with empty left %d rows", n)
	}
}

func TestReplaceItemCastDropsUnusableMembersAndKeepsBillingOrder(t *testing.T) {
	s := newBackfillServer(t, nil)
	storeCast(t, s, "m1", []metadata.CastMember{
		{ID: 1, Name: "First"},
		{ID: 0, Name: "No Id"},
		{ID: 3, Name: "   "},
		{ID: 4, Name: "  Fourth  ", Character: "  Hero ", ProfilePath: " /p.jpg "},
	})
	got := castRows(t, s, "m1")
	want := []metadata.CastMember{
		{ID: 1, Name: "First"},
		{ID: 4, Name: "Fourth", Character: "Hero", ProfilePath: "/p.jpg"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("cast = %+v, want %+v", got, want)
	}
	var ordinals []int
	rows, _ := s.db.Query(`SELECT ordinal FROM item_cast WHERE item_id='m1' ORDER BY ordinal`)
	defer rows.Close()
	for rows.Next() {
		var o int
		_ = rows.Scan(&o)
		ordinals = append(ordinals, o)
	}
	if !reflect.DeepEqual(ordinals, []int{0, 1}) {
		t.Errorf("ordinals = %v, want contiguous [0 1]", ordinals)
	}
}

// ---- content-rating backfill must not touch cast ----

func TestContentRatingBackfillLeavesCastUntouched(t *testing.T) {
	f := newFakeTMDb(t, func(p string, q url.Values) (int, string) {
		switch p {
		case "/movie/603":
			return 200, movieJSON(603, "R")
		case "/movie/700":
			return 200, movieJSON(700, "") // TMDb answers with no credits at all
		}
		return 404, `{}`
	})
	s := newBackfillServer(t, f)
	insertItem(t, s, itemFixture{id: "m1", typ: "movie", title: "The Matrix", tmdbID: 603, enriched: true})
	insertItem(t, s, itemFixture{id: "m2", typ: "movie", title: "Obscure", tmdbID: 700, enriched: true})
	cast := []metadata.CastMember{{ID: 1, Name: "Keanu", Character: "Neo", ProfilePath: "/k.jpg"}, {ID: 2, Name: "Carrie-Anne"}}
	storeCast(t, s, "m1", cast)
	storeCast(t, s, "m2", cast[:1])

	if err := drain(t, s); err != nil {
		t.Fatalf("drain: %v", err)
	}
	if st := stateOf(t, s, "m1"); st.rating.String != "R" {
		t.Fatalf("backfill did not run (rating %v)", st.rating)
	}
	if got := castRows(t, s, "m1"); !reflect.DeepEqual(got, cast) {
		t.Errorf("m1 cast changed by the content-rating backfill: %+v", got)
	}
	if got := castRows(t, s, "m2"); !reflect.DeepEqual(got, cast[:1]) {
		t.Errorf("m2 cast changed by the content-rating backfill (empty fetch is 'no information'): %+v", got)
	}
}

// ---- castMembers JSON shape ----

func TestItemDetailCastMembersShape(t *testing.T) {
	s := newBackfillServer(t, nil)
	insertItem(t, s, itemFixture{id: "m1", typ: "movie", title: "T", tmdbID: 5, enriched: true})
	setCastNames(t, s, "m1", "Neo Actor,Trinity Actor")
	storeCast(t, s, "m1", []metadata.CastMember{
		{ID: 6384, Name: "Keanu Reeves", Character: "Neo", ProfilePath: "/k.jpg"},
		{ID: 530, Name: "No Photo Person", Character: "", ProfilePath: ""},
	})
	d := detailJSON(t, s, "m1")

	want := []any{
		map[string]any{"personId": float64(6384), "name": "Keanu Reeves", "character": "Neo", "imageId": "cast-6384"},
		map[string]any{"personId": float64(530), "name": "No Photo Person", "character": nil, "imageId": nil},
	}
	if got := d["castMembers"]; !reflect.DeepEqual(got, any(want)) {
		t.Errorf("castMembers = %#v\nwant %#v", got, want)
	}
	// The legacy field is unchanged for older clients.
	legacy, _ := d["cast"].([]any)
	if len(legacy) != 2 || legacy[0].(map[string]any)["name"] != "Neo Actor" {
		t.Errorf("legacy cast = %#v", d["cast"])
	}
}

func TestItemDetailCastMembersFallsBackToCastNamesWithNulls(t *testing.T) {
	s := newBackfillServer(t, nil)
	insertItem(t, s, itemFixture{id: "m1", typ: "movie", title: "T", tmdbID: 5, enriched: true})
	setCastNames(t, s, "m1", "Ann Actor, Bob Actor ,, ")
	d := detailJSON(t, s, "m1")
	want := []any{
		map[string]any{"personId": nil, "name": "Ann Actor", "character": nil, "imageId": nil},
		map[string]any{"personId": nil, "name": "Bob Actor", "character": nil, "imageId": nil},
	}
	got, present := d["castMembers"]
	if !present || !reflect.DeepEqual(got, any(want)) {
		t.Errorf("castMembers = %#v (present=%v)\nwant %#v", got, present, want)
	}
}

func TestItemDetailCastMembersIsEmptyArrayNotNull(t *testing.T) {
	s := newBackfillServer(t, nil)
	insertItem(t, s, itemFixture{id: "m1", typ: "movie", title: "T", tmdbID: 5, enriched: true})
	rctx := chi.NewRouteContext()
	rctx.URLParams.Add("id", "m1")
	req := httptest.NewRequest(http.MethodGet, "/items/m1", nil)
	req = req.WithContext(context.WithValue(req.Context(), chi.RouteCtxKey, rctx))
	req = req.WithContext(context.WithValue(req.Context(), viewerKey, viewer{
		UserID: "u1", ProfileID: "p1", MaxAgeLevel: agerating.MaxLevel, IsOwner: true}))
	rec := httptest.NewRecorder()
	s.handleItemDetail(rec, req)
	if !strings.Contains(rec.Body.String(), `"castMembers":[]`) {
		t.Errorf("castMembers should serialize as [] when there is no cast: %s", rec.Body.String())
	}
}

func TestItemDetailCastRowsWinOverLegacyNames(t *testing.T) {
	s := newBackfillServer(t, nil)
	insertItem(t, s, itemFixture{id: "m1", typ: "movie", title: "T", tmdbID: 5, enriched: true})
	setCastNames(t, s, "m1", "Stale Name")
	storeCast(t, s, "m1", []metadata.CastMember{{ID: 1, Name: "Real Name"}})
	members, _ := detailJSON(t, s, "m1")["castMembers"].([]any)
	if len(members) != 1 || members[0].(map[string]any)["name"] != "Real Name" {
		t.Errorf("castMembers = %#v, want only the item_cast row", members)
	}
}

// ---- cast image route ----

func imageReq(s *Server, id string) *httptest.ResponseRecorder {
	rctx := chi.NewRouteContext()
	rctx.URLParams.Add("id", id)
	req := httptest.NewRequest(http.MethodGet, "/images/"+id, nil)
	req = req.WithContext(context.WithValue(req.Context(), chi.RouteCtxKey, rctx))
	rec := httptest.NewRecorder()
	s.handleImage(rec, req)
	return rec
}

func TestParseCastImageID(t *testing.T) {
	for _, c := range []struct {
		id     string
		person int
		isCast bool
	}{
		{"cast-6384", 6384, true},
		{"cast-0", 0, true},
		{"cast--5", 0, true},
		{"cast-abc", 0, true},
		{"cast-", 0, true},
		{"abc123def456", 0, false},
		{"Cast-1", 0, false},
	} {
		p, ok := parseCastImageID(c.id)
		if p != c.person || ok != c.isCast {
			t.Errorf("parseCastImageID(%q) = %d,%v want %d,%v", c.id, p, ok, c.person, c.isCast)
		}
	}
	if castImageID(6384) != "cast-6384" {
		t.Errorf("castImageID(6384) = %q", castImageID(6384))
	}
}

func TestCastImageRoute404WhenThereIsNoPhoto(t *testing.T) {
	s := newBackfillServer(t, nil)
	s.imageCache = metadata.NewImageCache(t.TempDir())
	storeCast(t, s, "m1", []metadata.CastMember{{ID: 530, Name: "No Photo", ProfilePath: ""}})

	for _, id := range []string{"cast-530", "cast-99999", "cast-0", "cast-abc"} {
		rec := imageReq(s, id)
		if rec.Code != http.StatusNotFound {
			t.Errorf("GET %s = %d, want 404 (%s)", id, rec.Code, rec.Body.String())
		}
	}
	if body := imageReq(s, "cast-530").Body.String(); !strings.Contains(body, "no_image_available") {
		t.Errorf("body = %s, want the no_image_available cause", body)
	}
}

func TestCastImageRouteServesTheCachedPhoto(t *testing.T) {
	s := newBackfillServer(t, nil)
	dir := t.TempDir()
	s.imageCache = metadata.NewImageCache(dir)
	storeCast(t, s, "m1", []metadata.CastMember{{ID: 6384, Name: "Keanu", ProfilePath: "/k.jpg"}})
	// Seed the cache entry the route will look up, so no request leaves the process.
	id := metadata.GenerateImageID("/k.jpg", metadata.ImageTypeProfile, 185)
	if err := os.WriteFile(filepath.Join(dir, id+".jpg"), []byte("JPEGBYTES"), 0o644); err != nil {
		t.Fatal(err)
	}
	rec := imageReq(s, "cast-6384")
	if rec.Code != http.StatusOK || rec.Body.String() != "JPEGBYTES" {
		t.Fatalf("GET cast-6384 = %d %q, want 200 with the cached bytes", rec.Code, rec.Body.String())
	}
	if cc := rec.Header().Get("Cache-Control"); cc != "public, max-age=604800" {
		t.Errorf("Cache-Control = %q", cc)
	}
	// An ordinary item id still goes the item path, not the cast path.
	if rec := imageReq(s, "nosuchitem"); rec.Code == http.StatusOK {
		t.Errorf("a non-cast id returned 200 with no such item")
	}
}

func TestCastImageRouteWithoutImageCacheIs503(t *testing.T) {
	s := newBackfillServer(t, nil)
	if rec := imageReq(s, "cast-1"); rec.Code != http.StatusServiceUnavailable {
		t.Errorf("GET with no image cache = %d, want 503", rec.Code)
	}
}

// ---- image cache cap setting ----

func TestImageCacheMaxBytesParsing(t *testing.T) {
	for _, c := range []struct {
		raw  string
		want int64
	}{
		{"", metadata.DefaultImageCacheMaxBytes},
		{"  ", metadata.DefaultImageCacheMaxBytes},
		{"0", 0},
		{"512", 512 << 20},
		{" 2048 ", 2048 << 20},
		{"-1", metadata.DefaultImageCacheMaxBytes},
		{"lots", metadata.DefaultImageCacheMaxBytes},
		{"1.5", metadata.DefaultImageCacheMaxBytes},
	} {
		if got := imageCacheMaxBytes(c.raw); got != c.want {
			t.Errorf("imageCacheMaxBytes(%q) = %d, want %d", c.raw, got, c.want)
		}
	}
}

// ---- scope=cast backfill ----

func castMovieJSON(id int, cast string) string {
	return `{"id":` + itoa(id) + `,"title":"M","credits":{"cast":[` + cast + `]}}`
}

func castTVJSON(id int, cast string) string {
	return `{"id":` + itoa(id) + `,"name":"S","credits":{"cast":[` + cast + `]}}`
}

func itoa(n int) string { b, _ := json.Marshal(n); return string(b) }

const twoCast = `{"id":11,"name":"Ann","character":"X","profile_path":"/a.jpg","order":0},{"id":12,"name":"Bob","character":"","profile_path":null,"order":1}`

func adminRefresh(s *Server, query string, admin bool) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, "/admin/metadata/refresh"+query, nil)
	name := "admin"
	if !admin {
		name = "someone"
	}
	req = req.WithContext(context.WithValue(req.Context(), userKey, authedUser{ID: "u1", Username: name}))
	rec := httptest.NewRecorder()
	s.handleAdminMetadataRefresh(rec, req)
	return rec
}

func castTestServer(t *testing.T, f *fakeTMDb) *Server {
	t.Helper()
	setKnobs(t, time.Millisecond, time.Millisecond, time.Millisecond, time.Millisecond)
	s := newBackfillServer(t, f)
	s.cfg.AdminUser = "admin"
	return s
}

func waitIdle(t *testing.T, s *Server) {
	t.Helper()
	waitFor(t, "cast backfill to finish", func() bool { return !s.castBackfillRunning.Load() })
}

func decodeBody(t *testing.T, rec *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &m); err != nil {
		t.Fatalf("decode %q: %v", rec.Body.String(), err)
	}
	return m
}

func TestCastBackfillWithoutTMDbIs400(t *testing.T) {
	s := castTestServer(t, nil)
	rec := adminRefresh(s, "?scope=cast", true)
	if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "tmdb_not_configured") {
		t.Errorf("= %d %s, want 400 tmdb_not_configured", rec.Code, rec.Body.String())
	}
}

func TestCastBackfillRequiresAdmin(t *testing.T) {
	s := castTestServer(t, newFakeTMDb(t, func(string, url.Values) (int, string) { return 404, `{}` }))
	if rec := adminRefresh(s, "?scope=cast", false); rec.Code != http.StatusForbidden {
		t.Errorf("non-admin = %d, want 403", rec.Code)
	}
}

func TestCastBackfillNothingToBackfillIs200(t *testing.T) {
	f := newFakeTMDb(t, func(string, url.Values) (int, string) { return 404, `{}` })
	s := castTestServer(t, f)
	// One item already has cast rows, one has no tmdb id: neither is pending.
	insertItem(t, s, itemFixture{id: "done", typ: "movie", title: "Done", tmdbID: 1, enriched: true})
	storeCast(t, s, "done", []metadata.CastMember{{ID: 1, Name: "A"}})
	insertItem(t, s, itemFixture{id: "noid", typ: "movie", title: "No Id", tmdbID: 0, enriched: true})

	rec := adminRefresh(s, "?scope=cast", true)
	body := decodeBody(t, rec)
	if rec.Code != http.StatusOK || body["reason"] != "nothing_to_backfill" || body["started"] != false {
		t.Errorf("= %d %s, want 200 nothing_to_backfill", rec.Code, rec.Body.String())
	}
	if s.castBackfillRunning.Load() {
		t.Errorf("run flag left set after an empty queue")
	}
	if n := len(f.snapshot()); n != 0 {
		t.Errorf("%d TMDb requests for an empty queue", n)
	}
}

func TestCastBackfillStartsFillsAndAsksOncePerLookup(t *testing.T) {
	f := newFakeTMDb(t, func(p string, q url.Values) (int, string) {
		switch p {
		case "/movie/603":
			return 200, castMovieJSON(603, twoCast)
		case "/tv/1396":
			return 200, castTVJSON(1396, twoCast)
		}
		return 404, `{}`
	})
	s := castTestServer(t, f)
	insertItem(t, s, itemFixture{id: "m1", typ: "movie", title: "Matrix", tmdbID: 603, enriched: true})
	insertItem(t, s, itemFixture{id: "e1", typ: "episode", title: "E1", tmdbID: 1396, showName: "S", enriched: true})
	insertItem(t, s, itemFixture{id: "e2", typ: "episode", title: "E2", tmdbID: 1396, showName: "S", enriched: true})
	var seqBefore int64
	_ = s.db.QueryRow(`SELECT COALESCE(SUM(change_seq),0) FROM items`).Scan(&seqBefore)

	rec := adminRefresh(s, "?scope=cast", true)
	body := decodeBody(t, rec)
	if rec.Code != http.StatusAccepted || body["started"] != true || body["scope"] != "cast" ||
		body["queued"] != float64(2) || body["items"] != float64(3) {
		t.Fatalf("= %d %s, want 202 started queued=2 items=3", rec.Code, rec.Body.String())
	}
	waitIdle(t, s)

	for _, id := range []string{"m1", "e1", "e2"} {
		got := castRows(t, s, id)
		want := []metadata.CastMember{{ID: 11, Name: "Ann", Character: "X", ProfilePath: "/a.jpg"}, {ID: 12, Name: "Bob"}}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("%s cast = %+v, want %+v", id, got, want)
		}
	}
	if got := f.paths(); len(got) != 2 {
		t.Errorf("TMDb paths = %v, want one request per distinct title (2), not per episode", got)
	}
	var seqAfter int64
	_ = s.db.QueryRow(`SELECT COALESCE(SUM(change_seq),0) FROM items`).Scan(&seqAfter)
	if seqAfter != seqBefore {
		t.Errorf("backfill changed change_seq (%d -> %d); it writes item_cast only", seqBefore, seqAfter)
	}
	// A second run finds nothing.
	if rec := adminRefresh(s, "?scope=cast", true); rec.Code != http.StatusOK {
		t.Errorf("second run = %d %s, want 200 nothing_to_backfill", rec.Code, rec.Body.String())
	}
}

func TestCastBackfillDoesNotRequeueTitlesTMDbHasNoCastFor(t *testing.T) {
	f := newFakeTMDb(t, func(p string, q url.Values) (int, string) {
		switch p {
		case "/movie/50":
			return 200, castMovieJSON(50, ``) // TMDb knows the title, lists nobody
		case "/movie/51":
			return 200, castMovieJSON(51, `{"id":0,"name":"No Person Id","order":0}`) // only unusable members
		}
		return 404, `{}`
	})
	s := castTestServer(t, f)
	insertItem(t, s, itemFixture{id: "a", typ: "movie", title: "A", tmdbID: 50, enriched: true})
	insertItem(t, s, itemFixture{id: "b", typ: "movie", title: "B", tmdbID: 51, enriched: true})

	if rec := adminRefresh(s, "?scope=cast", true); rec.Code != http.StatusAccepted {
		t.Fatalf("first run = %d %s", rec.Code, rec.Body.String())
	}
	waitIdle(t, s)
	if n := len(f.snapshot()); n != 2 {
		t.Fatalf("first run made %d requests, want 2", n)
	}
	rec := adminRefresh(s, "?scope=cast", true)
	if rec.Code != http.StatusOK || decodeBody(t, rec)["reason"] != "nothing_to_backfill" {
		t.Errorf("second run = %d %s, want 200 nothing_to_backfill (cast-less titles are asked once)", rec.Code, rec.Body.String())
	}
	if n := len(f.snapshot()); n != 2 {
		t.Errorf("second run made TMDb requests (%d total)", n)
	}
	if len(castRows(t, s, "a")) != 0 || len(castRows(t, s, "b")) != 0 {
		t.Errorf("rows were invented for a cast-less title")
	}
}

func TestCastBackfillLeavesFailedLookupsQueued(t *testing.T) {
	fail := true
	f := newFakeTMDb(t, func(p string, q url.Values) (int, string) {
		if p == "/movie/60" && fail {
			return 500, `{}`
		}
		return 200, castMovieJSON(60, twoCast)
	})
	s := castTestServer(t, f)
	insertItem(t, s, itemFixture{id: "a", typ: "movie", title: "A", tmdbID: 60, enriched: true})

	if rec := adminRefresh(s, "?scope=cast", true); rec.Code != http.StatusAccepted {
		t.Fatalf("first run = %d", rec.Code)
	}
	waitIdle(t, s)
	if len(castRows(t, s, "a")) != 0 {
		t.Fatalf("cast stored from a failed lookup")
	}
	fail = false
	if rec := adminRefresh(s, "?scope=cast", true); rec.Code != http.StatusAccepted {
		t.Fatalf("a failed lookup must stay queued; got %d %s", rec.Code, rec.Body.String())
	}
	waitIdle(t, s)
	if n := len(castRows(t, s, "a")); n != 2 {
		t.Errorf("after the retry cast rows = %d, want 2", n)
	}
}

func TestCastBackfillAlreadyRunningReportsNotStarted(t *testing.T) {
	f := newFakeTMDb(t, func(string, url.Values) (int, string) { return 404, `{}` })
	s := castTestServer(t, f)
	insertItem(t, s, itemFixture{id: "a", typ: "movie", title: "A", tmdbID: 60, enriched: true})
	s.castBackfillRunning.Store(true)
	rec := adminRefresh(s, "?scope=cast", true)
	body := decodeBody(t, rec)
	if rec.Code != http.StatusAccepted || body["started"] != false || body["reason"] != "cast_backfill_already_running" {
		t.Errorf("= %d %s", rec.Code, rec.Body.String())
	}
	if n := len(f.snapshot()); n != 0 {
		t.Errorf("a second run touched TMDb")
	}
}

func TestCastBackfillByTMDbIDNeverRematchesByTitle(t *testing.T) {
	// A hand-fixed match (tmdb_id differs from what a title search would give) is only read.
	f := newFakeTMDb(t, func(p string, q url.Values) (int, string) {
		if strings.HasPrefix(p, "/search") {
			t.Errorf("backfill searched TMDb by title: %s", p)
		}
		if p == "/movie/777" {
			return 200, castMovieJSON(777, twoCast)
		}
		return 404, `{}`
	})
	s := castTestServer(t, f)
	insertItem(t, s, itemFixture{id: "a", typ: "movie", title: "Wrong Title On Disk", tmdbID: 777, enriched: true})
	if rec := adminRefresh(s, "?scope=cast", true); rec.Code != http.StatusAccepted {
		t.Fatalf("= %d", rec.Code)
	}
	waitIdle(t, s)
	var tmdbID int
	_ = s.db.QueryRow(`SELECT tmdb_id FROM items WHERE id='a'`).Scan(&tmdbID)
	if tmdbID != 777 || len(castRows(t, s, "a")) != 2 {
		t.Errorf("tmdb_id=%d cast=%d, want 777 and 2", tmdbID, len(castRows(t, s, "a")))
	}
}

func TestExistingRefreshScopesStillWork(t *testing.T) {
	s := castTestServer(t, nil)
	if rec := adminRefresh(s, "?scope=bogus", true); rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "invalid_scope") {
		t.Errorf("bogus scope = %d %s", rec.Code, rec.Body.String())
	}
	if rec := adminRefresh(s, "?scope=all", true); rec.Code != http.StatusOK {
		t.Errorf("scope=all = %d %s", rec.Code, rec.Body.String())
	}
}
