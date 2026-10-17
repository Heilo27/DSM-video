package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"dsvideo/backend/internal/metadata"
	agerating "dsvideo/backend/internal/rating"

	"github.com/go-chi/chi/v5"

	_ "modernc.org/sqlite"
)

// TASK-915 backfill tests. They run the production schema (migrate) and the production client
// (metadata.NewTMDbClientWithBaseURL) against a local fake of TMDb, so what is asserted is the
// real request sequence and the real rows, not a re-implementation of either.

// ---- fake TMDb ----

type tmdbReq struct {
	path  string
	query url.Values
	at    time.Time
}

type fakeTMDb struct {
	t   *testing.T
	srv *httptest.Server

	mu   sync.Mutex
	reqs []tmdbReq
	// route returns the status and JSON body for a path; unknown paths are 404.
	route func(path string, q url.Values) (int, string)
	// onRequest, if set, runs for every request before it is answered.
	onRequest func(n int, path string)
}

func newFakeTMDb(t *testing.T, route func(path string, q url.Values) (int, string)) *fakeTMDb {
	t.Helper()
	f := &fakeTMDb{t: t, route: route}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		f.reqs = append(f.reqs, tmdbReq{path: r.URL.Path, query: r.URL.Query(), at: time.Now()})
		n := len(f.reqs)
		hook := f.onRequest
		f.mu.Unlock()
		if hook != nil {
			hook(n, r.URL.Path)
		}
		status, body := f.route(r.URL.Path, r.URL.Query())
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeTMDb) client() *metadata.TMDbClient {
	return metadata.NewTMDbClientWithBaseURL("test-key", f.srv.URL)
}

func (f *fakeTMDb) snapshot() []tmdbReq {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]tmdbReq(nil), f.reqs...)
}

func (f *fakeTMDb) paths() []string {
	var out []string
	for _, r := range f.snapshot() {
		out = append(out, r.path)
	}
	return out
}

// ---- fixtures ----

func movieJSON(id int, cert string) string {
	rel := `"release_dates":{"results":[]}`
	if cert != "" {
		rel = fmt.Sprintf(`"release_dates":{"results":[{"iso_3166_1":"US","release_dates":[{"certification":%q,"type":3,"release_date":"2019-01-01"}]}]}`, cert)
	}
	return fmt.Sprintf(`{"id":%d,"title":"M%d",
		"production_companies":[{"id":2,"name":"Walt Disney Pictures"}],
		"keywords":{"keywords":[{"id":7,"name":"christmas"}]},%s}`, id, id, rel)
}

func tvJSON(id int, rating string) string {
	cr := `"content_ratings":{"results":[]}`
	if rating != "" {
		cr = fmt.Sprintf(`"content_ratings":{"results":[{"iso_3166_1":"GB","rating":"15"},{"iso_3166_1":"US","rating":%q}]}`, rating)
	}
	return fmt.Sprintf(`{"id":%d,"name":"S%d",
		"production_companies":[{"id":9,"name":"Some Studio"}],
		"networks":[{"id":2,"name":"ABC"}],
		"keywords":{"results":[{"id":7,"name":"christmas"}]},%s}`, id, id, cr)
}

func newBackfillServer(t *testing.T, f *fakeTMDb) *Server {
	t.Helper()
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "t.db")+"?_pragma=busy_timeout(5000)")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	if err := migrate(db); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	s := &Server{db: db, metaSemaphore: make(chan struct{}, 2)}
	if f != nil {
		s.tmdbClient = f.client()
	}
	return s
}

type itemFixture struct {
	id, typ, title string
	year           int // 0 = NULL
	tmdbID         int
	showName       string
	enriched       bool   // metadata_fetched_at set
	checkedAt      string // tmdb_extras_checked_at; "" = NULL
	contentRating  string // pre-existing content_rating; "" = NULL
}

func insertItem(t *testing.T, s *Server, it itemFixture) {
	t.Helper()
	lib := "lib_movies"
	if it.typ == "episode" {
		lib = "lib_tv"
	}
	var year, show, fetched, checked, rating any
	if it.year != 0 {
		year = it.year
	}
	if it.showName != "" {
		show = it.showName
	}
	if it.enriched {
		fetched = "2026-01-01T00:00:00Z"
	}
	if it.checkedAt != "" {
		checked = it.checkedAt
	}
	if it.contentRating != "" {
		rating = it.contentRating
	}
	_, err := s.db.Exec(`INSERT INTO items(id, library_id, type, title, year, path, added_at, updated_at,
		tmdb_id, show_name, metadata_fetched_at, tmdb_extras_checked_at, content_rating, change_seq)
		VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,0)`,
		it.id, lib, it.typ, it.title, year, "/x/"+it.id, "2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z",
		it.tmdbID, show, fetched, checked, rating)
	if err != nil {
		t.Fatalf("insert %s: %v", it.id, err)
	}
}

type itemState struct {
	rating  sql.NullString
	checked sql.NullString
	seq     int64
}

func stateOf(t *testing.T, s *Server, id string) itemState {
	t.Helper()
	var st itemState
	err := s.db.QueryRow(`SELECT content_rating, tmdb_extras_checked_at, COALESCE(change_seq,0) FROM items WHERE id = ?`, id).
		Scan(&st.rating, &st.checked, &st.seq)
	if err != nil {
		t.Fatalf("state of %s: %v", id, err)
	}
	return st
}

// drain runs units until the queue is empty, the way the loop does minus the waiting.
// It returns the first error a unit reports.
func drain(t *testing.T, s *Server) error {
	t.Helper()
	ctx := context.Background()
	for i := 0; i < 100; i++ {
		u, ok, err := s.nextRatingUnit(ctx, map[string]bool{})
		if err != nil {
			t.Fatalf("nextRatingUnit: %v", err)
		}
		if !ok {
			return nil
		}
		if err := s.processRatingUnit(ctx, s.tmdbClient, u); err != nil {
			return err
		}
	}
	t.Fatalf("queue never drained: a processed unit is being selected again")
	return nil
}

func setKnobs(t *testing.T, start, pace, idle, backoff time.Duration) {
	t.Helper()
	oS, oP, oI, oB, oM := contentRatingBackfillStartDelay, contentRatingBackfillPace,
		contentRatingBackfillIdle, contentRatingBackfillBackoffBase, contentRatingBackfillBackoffMax
	contentRatingBackfillStartDelay, contentRatingBackfillPace = start, pace
	contentRatingBackfillIdle, contentRatingBackfillBackoffBase = idle, backoff
	contentRatingBackfillBackoffMax = backoff * 8
	t.Cleanup(func() {
		contentRatingBackfillStartDelay, contentRatingBackfillPace = oS, oP
		contentRatingBackfillIdle, contentRatingBackfillBackoffBase = oI, oB
		contentRatingBackfillBackoffMax = oM
	})
}

// startLoop runs the production loop and returns a stop func that cancels it and waits for exit.
func startLoop(t *testing.T, s *Server) (ctx context.Context, stop func()) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { defer close(done); s.runContentRatingBackfill(ctx) }()
	var once sync.Once
	stop = func() {
		once.Do(func() {
			cancel()
			select {
			case <-done:
			case <-time.After(5 * time.Second):
				t.Error("backfill loop did not exit after cancel")
			}
		})
	}
	t.Cleanup(stop)
	return ctx, stop
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

func countRows(t *testing.T, s *Server, q string, args ...any) int {
	t.Helper()
	var n int
	if err := s.db.QueryRow(q, args...).Scan(&n); err != nil {
		t.Fatalf("%s: %v", q, err)
	}
	return n
}

// ---- movies ----

func TestBackfillMovieStoresRatingTagsAndAdvancesChangeSeq(t *testing.T) {
	f := newFakeTMDb(t, func(p string, q url.Values) (int, string) {
		if p == "/movie/603" {
			return 200, movieJSON(603, "R")
		}
		return 404, `{}`
	})
	s := newBackfillServer(t, f)
	insertItem(t, s, itemFixture{id: "m1", typ: "movie", title: "The Matrix", tmdbID: 603, enriched: true})

	if err := drain(t, s); err != nil {
		t.Fatalf("drain: %v", err)
	}

	st := stateOf(t, s, "m1")
	if !st.rating.Valid || st.rating.String != "R" {
		t.Errorf("content_rating = %+v, want R", st.rating)
	}
	if !st.checked.Valid {
		t.Error("tmdb_extras_checked_at not stamped")
	}
	if st.seq <= 0 {
		t.Error("change_seq not bumped: clients on delta sync would never receive the new rating")
	}
	if got := f.snapshot(); len(got) != 1 {
		t.Fatalf("want exactly 1 TMDb request for one movie, got %v", f.paths())
	}
	if ap := f.snapshot()[0].query.Get("append_to_response"); ap != "release_dates,keywords" {
		t.Errorf("append_to_response = %q: credits must not be fetched by the backfill", ap)
	}
	if n := countRows(t, s, `SELECT COUNT(*) FROM item_companies WHERE item_id='m1' AND kind='company' AND company_id=2`); n != 1 {
		t.Errorf("company row missing")
	}
	if n := countRows(t, s, `SELECT COUNT(*) FROM item_keywords WHERE item_id='m1' AND keyword_id=7`); n != 1 {
		t.Errorf("keyword row missing")
	}
}

// A title TMDb answers for but has no US certification for must terminate: content_rating stays
// NULL (unrated) and the row leaves the queue, so it is never asked about again.
func TestBackfillNoUSCertIsStampedAndNeverRetried(t *testing.T) {
	cases := map[string]string{
		"no US entry": movieJSON(10, ""),
		"NR":          movieJSON(10, "NR"),
		"Not Rated":   movieJSON(10, "Not Rated"),
		"Unrated":     movieJSON(10, " Unrated "),
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			f := newFakeTMDb(t, func(p string, q url.Values) (int, string) { return 200, body })
			s := newBackfillServer(t, f)
			insertItem(t, s, itemFixture{id: "m1", typ: "movie", title: "Obscure", tmdbID: 10, enriched: true})

			if err := drain(t, s); err != nil {
				t.Fatalf("drain: %v", err)
			}
			st := stateOf(t, s, "m1")
			if st.rating.Valid {
				t.Errorf("content_rating = %q, want NULL (unrated)", st.rating.String)
			}
			if !st.checked.Valid {
				t.Fatal("not stamped: the backfill would ask TMDb about this title forever")
			}
			if st.seq != 0 {
				t.Errorf("change_seq = %d: nothing client-visible changed, no sequence should be spent", st.seq)
			}

			before := len(f.snapshot())
			if err := drain(t, s); err != nil {
				t.Fatalf("second drain: %v", err)
			}
			if after := len(f.snapshot()); after != before {
				t.Errorf("an unrated title was re-requested: %d -> %d requests", before, after)
			}
		})
	}
}

func TestBackfillOnlyTouchesEnrichedUncheckedRows(t *testing.T) {
	f := newFakeTMDb(t, func(p string, q url.Values) (int, string) { return 200, movieJSON(1, "PG") })
	s := newBackfillServer(t, f)
	insertItem(t, s, itemFixture{id: "never-enriched", typ: "movie", title: "A", tmdbID: 1})
	insertItem(t, s, itemFixture{id: "no-tmdb-id", typ: "movie", title: "B", enriched: true})
	insertItem(t, s, itemFixture{id: "already-checked", typ: "movie", title: "C", tmdbID: 3, enriched: true, checkedAt: "2026-02-02T00:00:00Z", contentRating: "G"})

	if err := drain(t, s); err != nil {
		t.Fatalf("drain: %v", err)
	}
	if got := f.snapshot(); len(got) != 0 {
		t.Errorf("no row was eligible but TMDb was asked: %v", f.paths())
	}
	if st := stateOf(t, s, "already-checked"); st.rating.String != "G" {
		t.Errorf("a finished row was overwritten: %+v", st.rating)
	}
}

// ---- failures ----

func TestBackfill404IsStampedUnratedButServerErrorsAreNotStamped(t *testing.T) {
	status := http.StatusNotFound
	f := newFakeTMDb(t, func(p string, q url.Values) (int, string) { return status, `{"status_message":"x"}` })
	s := newBackfillServer(t, f)
	insertItem(t, s, itemFixture{id: "m1", typ: "movie", title: "Gone", tmdbID: 5, enriched: true})

	if err := drain(t, s); err != nil {
		t.Fatalf("a 404 is a permanent answer and must finish the unit, got %v", err)
	}
	st := stateOf(t, s, "m1")
	if !st.checked.Valid || st.rating.Valid {
		t.Errorf("404 must stamp checked and leave unrated, got %+v", st)
	}

	for _, code := range []int{http.StatusInternalServerError, http.StatusTooManyRequests, http.StatusUnauthorized} {
		status = code
		insertItem(t, s, itemFixture{id: fmt.Sprintf("t%d", code), typ: "movie", title: "T", tmdbID: 6, enriched: true})
		if err := drain(t, s); err == nil {
			t.Errorf("status %d must be reported as a failure", code)
		}
		if st := stateOf(t, s, fmt.Sprintf("t%d", code)); st.checked.Valid {
			t.Errorf("status %d was recorded as a finished check: the title would never be retried", code)
		}
		if _, err := s.db.Exec(`UPDATE items SET tmdb_extras_checked_at = '2026-03-03T00:00:00Z' WHERE id = ?`, fmt.Sprintf("t%d", code)); err != nil {
			t.Fatal(err)
		}
	}
}

// One title that always fails must not block the queue behind it: after MaxFailures it is
// skipped for the rest of the run and the others complete.
func TestBackfillPoisonedTitleDoesNotBlockTheQueue(t *testing.T) {
	f := newFakeTMDb(t, func(p string, q url.Values) (int, string) {
		if p == "/movie/1" {
			return 500, `boom`
		}
		return 200, movieJSON(2, "PG")
	})
	s := newBackfillServer(t, f)
	insertItem(t, s, itemFixture{id: "a-poison", typ: "movie", title: "Poison", tmdbID: 1, enriched: true})
	insertItem(t, s, itemFixture{id: "b-fine", typ: "movie", title: "Fine", tmdbID: 2, enriched: true})
	setKnobs(t, 0, time.Millisecond, time.Hour, time.Millisecond)
	startLoop(t, s)

	waitFor(t, "healthy title behind the poisoned one to finish", func() bool {
		return stateOf(t, s, "b-fine").checked.Valid
	})
	if stateOf(t, s, "a-poison").checked.Valid {
		t.Error("the poisoned title was stamped as checked")
	}
	n := 0
	for _, p := range f.paths() {
		if p == "/movie/1" {
			n++
		}
	}
	if n != contentRatingBackfillMaxFailures {
		t.Errorf("poisoned title requested %d times, want exactly %d before being skipped", n, contentRatingBackfillMaxFailures)
	}
}

// ---- pacing ----

func TestBackfillIsPacedAndWaitsOutStartDelayAndScans(t *testing.T) {
	const pace = 80 * time.Millisecond
	const startDelay = 150 * time.Millisecond
	f := newFakeTMDb(t, func(p string, q url.Values) (int, string) { return 200, movieJSON(1, "PG") })
	s := newBackfillServer(t, f)
	for i := 0; i < 4; i++ {
		insertItem(t, s, itemFixture{id: fmt.Sprintf("m%d", i), typ: "movie", title: "T", tmdbID: 100 + i, enriched: true})
	}
	s.scanInProgress.Store(true)
	setKnobs(t, startDelay, pace, time.Hour, time.Millisecond)
	began := time.Now()
	startLoop(t, s)

	// Past the start delay, but a scan is running: still nothing may be requested.
	time.Sleep(startDelay + 4*pace + 100*time.Millisecond)
	if n := len(f.snapshot()); n != 0 {
		t.Fatalf("backfill hit TMDb %d times while a scan was in progress", n)
	}
	s.scanInProgress.Store(false)
	waitFor(t, "all four movies", func() bool { return len(f.snapshot()) == 4 })

	reqs := f.snapshot()
	if reqs[0].at.Sub(began) < startDelay {
		t.Errorf("first request %s after start, want >= start delay %s", reqs[0].at.Sub(began), startDelay)
	}
	for i := 1; i < len(reqs); i++ {
		// Timer slack only ever lengthens a wait; allow a little for clock granularity.
		if gap := reqs[i].at.Sub(reqs[i-1].at); gap < pace-15*time.Millisecond {
			t.Errorf("requests %d and %d were %s apart, want >= pace %s", i-1, i, gap, pace)
		}
	}
}

// Production pacing must stay gentle. This pins the shipped values, not the test knobs.
func TestBackfillProductionPacingIsConservative(t *testing.T) {
	if contentRatingBackfillPace < time.Second {
		t.Errorf("pace %s: more than one TMDb unit per second is not gentle on a NAS", contentRatingBackfillPace)
	}
	if contentRatingBackfillStartDelay < time.Minute {
		t.Errorf("start delay %s: the backfill must not compete with startup", contentRatingBackfillStartDelay)
	}
	if contentRatingBackfillMaxFailures < 2 || contentRatingBackfillTxChunk <= 0 {
		t.Error("failure cap / tx chunk must be positive")
	}
}

// ---- resume ----

// Progress is the database. Stop the loop part-way, start a fresh one (a restart), and it asks
// only about what is left: stamped rows are never requested again.
func TestBackfillResumesFromDatabaseState(t *testing.T) {
	var s *Server
	f := newFakeTMDb(t, func(p string, q url.Values) (int, string) { return 200, movieJSON(1, "PG") })
	s = newBackfillServer(t, f)
	for i := 0; i < 6; i++ {
		insertItem(t, s, itemFixture{id: fmt.Sprintf("m%d", i), typ: "movie", title: "T", tmdbID: 100 + i, enriched: true})
	}
	// m0 was finished by an earlier run.
	if _, err := s.db.Exec(`UPDATE items SET content_rating='G', tmdb_extras_checked_at='2026-01-02T00:00:00Z' WHERE id='m0'`); err != nil {
		t.Fatal(err)
	}

	setKnobs(t, 0, 30*time.Millisecond, time.Hour, time.Millisecond)
	_, stop := startLoop(t, s)
	waitFor(t, "run 1 to finish two movies", func() bool {
		return countRows(t, s, `SELECT COUNT(*) FROM items WHERE tmdb_extras_checked_at IS NOT NULL`) >= 3
	})
	stop() // simulated restart

	remaining := map[string]bool{}
	rows, err := s.db.Query(`SELECT tmdb_id FROM items WHERE tmdb_extras_checked_at IS NULL`)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var id int
		if err := rows.Scan(&id); err != nil {
			t.Fatal(err)
		}
		remaining[fmt.Sprintf("/movie/%d", id)] = true
	}
	rows.Close()
	if len(remaining) == 0 || len(remaining) >= 5 {
		t.Fatalf("run 1 should have stopped part-way, %d rows left", len(remaining))
	}

	mark := len(f.snapshot())
	startLoop(t, s)
	waitFor(t, "run 2 to finish the queue", func() bool {
		return countRows(t, s, `SELECT COUNT(*) FROM items WHERE tmdb_extras_checked_at IS NULL`) == 0
	})
	got := map[string]bool{}
	for _, r := range f.snapshot()[mark:] {
		got[r.path] = true
	}
	if len(got) != len(remaining) {
		t.Errorf("run 2 requested %v, want exactly the unfinished %v", got, remaining)
	}
	for p := range got {
		if !remaining[p] {
			t.Errorf("run 2 re-requested %s, which run 1 had already finished", p)
		}
	}
	if st := stateOf(t, s, "m0"); st.rating.String != "G" {
		t.Errorf("m0, finished by an earlier run, was overwritten: %+v", st.rating)
	}
}

// ---- shows ----

// An episode's tmdb_id is the EPISODE's TMDb id. The backfill must find the show by name and
// year, ask TMDb about the show once, and give every episode the show's rating.
func TestBackfillShowIsLookedUpByNameAndYearNotByEpisodeTMDbID(t *testing.T) {
	const episodeTMDbID = 99991
	f := newFakeTMDb(t, func(p string, q url.Values) (int, string) {
		switch p {
		case "/search/tv":
			if q.Get("query") == "Breaking Bad" && q.Get("first_air_date_year") == "2008" {
				return 200, `{"results":[
					{"id":111,"name":"Breaking Bad Fan Show","original_name":"Breaking Bad Fan Show"},
					{"id":1396,"name":"Breaking Bad","original_name":"Breaking Bad"}]}`
			}
			return 200, `{"results":[]}`
		case "/tv/1396":
			return 200, tvJSON(1396, "TV-MA")
		}
		return 404, `{}`
	})
	s := newBackfillServer(t, f)
	for i := 1; i <= 5; i++ {
		insertItem(t, s, itemFixture{id: fmt.Sprintf("bb%d", i), typ: "episode", title: fmt.Sprintf("Ep %d", i),
			year: 2008, tmdbID: episodeTMDbID + i, showName: "Breaking Bad", enriched: true})
	}
	// Same show name, different first-air year: a different show (a remake). Not this lookup's.
	insertItem(t, s, itemFixture{id: "remake1", typ: "episode", title: "R1", year: 2030, tmdbID: 5,
		showName: "Breaking Bad", enriched: true, checkedAt: "2026-01-02T00:00:00Z"})

	u, ok, err := s.nextRatingUnit(context.Background(), map[string]bool{})
	if err != nil || !ok {
		t.Fatalf("nextRatingUnit ok=%v err=%v", ok, err)
	}
	if u.isMovie() || u.showName != "Breaking Bad" || len(u.itemIDs) != 5 {
		t.Fatalf("unit = %+v, want one show unit of 5 episodes (the finished remake row excluded)", u)
	}
	if err := drain(t, s); err != nil {
		t.Fatalf("drain: %v", err)
	}

	for i := 1; i <= 5; i++ {
		st := stateOf(t, s, fmt.Sprintf("bb%d", i))
		if st.rating.String != "TV-MA" || !st.checked.Valid || st.seq <= 0 {
			t.Errorf("episode bb%d = %+v, want TV-MA, stamped, change_seq bumped", i, st)
		}
	}
	if st := stateOf(t, s, "remake1"); st.rating.Valid {
		t.Errorf("a finished row of another show was rewritten: %+v", st)
	}

	// Exactly two requests for five episodes: search + show detail. Never the episode id.
	paths := f.paths()
	want := []string{"/search/tv", "/tv/1396"}
	if strings.Join(paths, ",") != strings.Join(want, ",") {
		t.Errorf("requests = %v, want %v", paths, want)
	}
	for _, p := range paths {
		if strings.Contains(p, fmt.Sprint(episodeTMDbID)) {
			t.Errorf("episode tmdb_id leaked into a request: %s", p)
		}
	}
	if ap := f.snapshot()[1].query.Get("append_to_response"); ap != "content_ratings,keywords" {
		t.Errorf("append_to_response = %q", ap)
	}
	// Show-level tags land on every episode.
	if n := countRows(t, s, `SELECT COUNT(*) FROM item_companies WHERE item_id LIKE 'bb%' AND kind='network'`); n != 5 {
		t.Errorf("network rows on episodes = %d, want 5", n)
	}
}

// The search returns near-misses. Taking results[0] would hand a show somebody else's rating;
// no exact name match must resolve to unrated and a finished check.
func TestBackfillShowWithNoExactNameMatchIsUnratedNotTheFirstResult(t *testing.T) {
	f := newFakeTMDb(t, func(p string, q url.Values) (int, string) {
		if p == "/search/tv" {
			return 200, `{"results":[{"id":7,"name":"Totally Different Show","original_name":"Other"}]}`
		}
		return 200, tvJSON(7, "TV-MA")
	})
	s := newBackfillServer(t, f)
	insertItem(t, s, itemFixture{id: "e1", typ: "episode", title: "E", year: 2015, tmdbID: 1, showName: "Kids Cartoon", enriched: true})

	if err := drain(t, s); err != nil {
		t.Fatalf("drain: %v", err)
	}
	st := stateOf(t, s, "e1")
	if st.rating.Valid {
		t.Errorf("rating = %q: a near-miss search result leaked its rating onto an unrelated show", st.rating.String)
	}
	if !st.checked.Valid {
		t.Error("not stamped, would be retried forever")
	}
	if got := f.paths(); len(got) != 1 || got[0] != "/search/tv" {
		t.Errorf("requests = %v, want only the search", got)
	}
}

func TestBackfillShowNameMatchIsCaseInsensitive(t *testing.T) {
	f := newFakeTMDb(t, func(p string, q url.Values) (int, string) {
		if p == "/search/tv" {
			return 200, `{"results":[{"id":7,"name":"THE SHOW","original_name":"x"}]}`
		}
		return 200, tvJSON(7, "TV-14")
	})
	s := newBackfillServer(t, f)
	insertItem(t, s, itemFixture{id: "e1", typ: "episode", title: "E", year: 2015, showName: "The Show", enriched: true})
	if err := drain(t, s); err != nil {
		t.Fatalf("drain: %v", err)
	}
	if st := stateOf(t, s, "e1"); st.rating.String != "TV-14" {
		t.Errorf("rating = %+v, want TV-14", st.rating)
	}
}

func TestBackfillShowWithNullYearSearchesWithoutAYear(t *testing.T) {
	f := newFakeTMDb(t, func(p string, q url.Values) (int, string) {
		if p == "/search/tv" {
			if _, has := q["first_air_date_year"]; has {
				return 500, `year must not be sent when unknown`
			}
			return 200, `{"results":[{"id":7,"name":"Yearless","original_name":"Yearless"}]}`
		}
		return 200, tvJSON(7, "TV-G")
	})
	s := newBackfillServer(t, f)
	insertItem(t, s, itemFixture{id: "e1", typ: "episode", title: "E", showName: "Yearless", enriched: true})
	if err := drain(t, s); err != nil {
		t.Fatalf("drain: %v", err)
	}
	if st := stateOf(t, s, "e1"); st.rating.String != "TV-G" {
		t.Errorf("rating = %+v, want TV-G", st.rating)
	}
}

// ---- tags ----

// TMDb company ids and network ids are separate id spaces: company 2 is Walt Disney Pictures,
// network 2 is ABC. Both must be kept, distinguished by kind, for the same item.
func TestItemTagsKeepCompanyAndNetworkWithTheSameIDDistinct(t *testing.T) {
	s := newBackfillServer(t, nil)
	ctx := context.Background()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	err = replaceItemTags(ctx, tx, "show1", metadata.Extras{
		Companies: []metadata.Company{{ID: 2, Name: " Walt Disney Pictures "}},
		Networks:  []metadata.Company{{ID: 2, Name: "ABC"}},
	})
	if err != nil {
		t.Fatalf("replaceItemTags: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}

	names := map[string]string{}
	rows, err := s.db.Query(`SELECT kind, name FROM item_companies WHERE item_id='show1' AND company_id=2`)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var k, n string
		if err := rows.Scan(&k, &n); err != nil {
			t.Fatal(err)
		}
		names[k] = n
	}
	rows.Close()
	if len(names) != 2 || names["company"] != "Walt Disney Pictures" || names["network"] != "ABC" {
		t.Errorf("rows for id 2 = %v, want company=Walt Disney Pictures (trimmed) and network=ABC", names)
	}
	// A lookup by company id alone, the bug the kind column prevents, must be scoped by kind.
	if n := countRows(t, s, `SELECT COUNT(*) FROM item_companies WHERE kind='company' AND company_id=2`); n != 1 {
		t.Errorf("company-scoped lookup of id 2 returned %d rows, want 1 (ABC must not match)", n)
	}
}

func TestItemTagsAreReplacedNotMerged(t *testing.T) {
	s := newBackfillServer(t, nil)
	ctx := context.Background()
	write := func(e metadata.Extras) {
		tx, err := s.db.BeginTx(ctx, nil)
		if err != nil {
			t.Fatal(err)
		}
		if err := replaceItemTags(ctx, tx, "i1", e); err != nil {
			t.Fatalf("replaceItemTags: %v", err)
		}
		if err := tx.Commit(); err != nil {
			t.Fatal(err)
		}
	}
	write(metadata.Extras{
		Companies: []metadata.Company{{ID: 1, Name: "Old Studio"}, {ID: 0, Name: "no id"}},
		Keywords:  []metadata.Keyword{{ID: 5, Name: "old"}, {ID: 5, Name: "old dup"}},
	})
	if n := countRows(t, s, `SELECT COUNT(*) FROM item_companies WHERE item_id='i1'`); n != 1 {
		t.Errorf("entries without a TMDb id must be dropped, got %d company rows", n)
	}
	if n := countRows(t, s, `SELECT COUNT(*) FROM item_keywords WHERE item_id='i1'`); n != 1 {
		t.Errorf("duplicate keyword ids must collapse, got %d", n)
	}

	// A manual TMDb re-match to a different title: the old title's tags must not linger.
	write(metadata.Extras{
		Companies: []metadata.Company{{ID: 2, Name: "New Studio"}},
		Keywords:  []metadata.Keyword{{ID: 6, Name: "new"}},
	})
	var ids []string
	rows, err := s.db.Query(`SELECT 'c'||company_id FROM item_companies WHERE item_id='i1' UNION ALL SELECT 'k'||keyword_id FROM item_keywords WHERE item_id='i1'`)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids = append(ids, id)
	}
	rows.Close()
	sort.Strings(ids)
	if strings.Join(ids, ",") != "c2,k6" {
		t.Errorf("tags after re-match = %v, want [c2 k6]", ids)
	}
}

// End to end through the real GET /items/{id} handler: a rated title reports its rating, an
// unrated one reports null.
func TestItemDetailReportsBackfilledRatingAndNullForUnrated(t *testing.T) {
	f := newFakeTMDb(t, func(p string, q url.Values) (int, string) {
		if p == "/movie/603" {
			return 200, movieJSON(603, "R")
		}
		return 200, movieJSON(10, "NR")
	})
	s := newBackfillServer(t, f)
	insertItem(t, s, itemFixture{id: "rated", typ: "movie", title: "The Matrix", tmdbID: 603, enriched: true})
	insertItem(t, s, itemFixture{id: "unrated", typ: "movie", title: "Obscure", tmdbID: 10, enriched: true})
	if err := drain(t, s); err != nil {
		t.Fatalf("drain: %v", err)
	}

	get := func(id string) map[string]any {
		rctx := chi.NewRouteContext()
		rctx.URLParams.Add("id", id)
		req := httptest.NewRequest(http.MethodGet, "/items/"+id, nil)
		req = req.WithContext(context.WithValue(req.Context(), chi.RouteCtxKey, rctx))
		// FR-250: detail applies the viewer's ceiling; an unrestricted owner sees both titles.
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
	if got := get("rated")["contentRating"]; got != "R" {
		t.Errorf("rated contentRating = %v, want R", got)
	}
	if got, present := get("unrated")["contentRating"]; !present || got != nil {
		t.Errorf("unrated contentRating = %v (present=%v), want explicit null", got, present)
	}
}
