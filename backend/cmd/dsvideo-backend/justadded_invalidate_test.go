package main

import (
	"bytes"
	"context"
	"log"
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

// TASK-934: a TMDb re-match takes a fresh change_seq on every row it rewrites, and the Just
// Added rails never outlive a rating change or a scan. Ryan, 2026-10-17: New Arrivals must
// never let an adult title through to a kids' profile just because it is the newest.

const (
	jaMovieTMDb = 501 // re-matches to an R film
	jaTVTMDb    = 601 // re-matches to a TV-MA show (single-episode fix)
	jaShowTMDb  = 701 // re-matches to a TV-MA show (whole-show fix)
)

type jaEnv struct {
	*qaEnv
	owner, kid string
}

func newJAEnv(t *testing.T) *jaEnv {
	t.Helper()
	e := newQAEnv(t)
	e.s.cfg.TVPath = "/tv"
	fake := newFakeTMDb(t, func(p string, _ url.Values) (int, string) {
		switch p {
		case "/movie/501":
			return 200, movieJSON(jaMovieTMDb, "R")
		case "/tv/601":
			return 200, tvJSON(jaTVTMDb, "TV-MA")
		case "/tv/701":
			return 200, tvJSON(jaShowTMDb, "TV-MA")
		}
		return 404, `{}`
	})
	e.s.tmdbMu.Lock()
	e.s.tmdbClient = fake.client()
	e.s.tmdbMu.Unlock()
	owner, kid := e.pcFamily() // kid: Older Kids (level 2)
	return &jaEnv{qaEnv: e, owner: owner, kid: kid}
}

func jaCert(c string) *string { return &c }

// rail returns the ids on profile's Just Added rail (all libraries).
func (e *jaEnv) rail(profile string) []string {
	e.t.Helper()
	r := e.do(qaAlice, "GET", "/just-added?limit=24", "", profile)
	wantOK(e.t, r, 200)
	items, _ := r.js["items"].([]any)
	ids := make([]string, 0, len(items))
	for _, it := range items {
		m, _ := it.(map[string]any)
		id, _ := m["id"].(string)
		ids = append(ids, id)
	}
	return ids
}

func (e *jaEnv) changeSeq(id string) int64 {
	e.t.Helper()
	var seq int64
	if err := e.db.QueryRow(`SELECT COALESCE(change_seq, 0) FROM items WHERE id = ?`, id).Scan(&seq); err != nil {
		e.t.Fatalf("change_seq of %s: %v", id, err)
	}
	return seq
}

func (e *jaEnv) contentRating(id string) string {
	e.t.Helper()
	var c *string
	if err := e.db.QueryRow(`SELECT content_rating FROM items WHERE id = ?`, id).Scan(&c); err != nil {
		e.t.Fatalf("content_rating of %s: %v", id, err)
	}
	if c == nil {
		return ""
	}
	return *c
}

func jaContains(ids []string, id string) bool {
	for _, x := range ids {
		if x == id {
			return true
		}
	}
	return false
}

// assertSeqBumpedAndPublished checks a re-matched row carries a change_seq newer than before
// and that the sync high-water mark already advertises it.
func (e *jaEnv) assertSeqBumpedAndPublished(id string, before int64) {
	e.t.Helper()
	after := e.changeSeq(id)
	if after <= before {
		e.t.Errorf("%s: change_seq %d -> %d, want a new sequence after the re-match", id, before, after)
	}
	if pub := e.s.cachedItemSeq.Load(); pub < after {
		e.t.Errorf("%s: published item_seq %d is behind the row's change_seq %d", id, pub, after)
	}
}

func TestTASK934_MovieFixBumpsChangeSeqAndDropsReRatedTitleFromKidsRail(t *testing.T) {
	e := newJAEnv(t)
	e.pcMovie("ja_mov", jaCert("G"), 50)
	if !jaContains(e.rail(e.kid), "ja_mov") {
		t.Fatalf("precondition: a G film is on the Older Kids rail: %v", e.rail(e.kid))
	}
	before := e.changeSeq("ja_mov")

	r := e.do(qaAlice, "POST", "/items/ja_mov/tmdb-fix", `{"tmdbId":501,"type":"movie"}`, e.owner)
	wantOK(t, r, 200)
	if got := e.contentRating("ja_mov"); got != "R" {
		t.Fatalf("re-match stored content_rating %q, want R", got)
	}
	e.assertSeqBumpedAndPublished("ja_mov", before)

	if kid := e.rail(e.kid); jaContains(kid, "ja_mov") {
		t.Errorf("R film still on the Older Kids rail after the re-match: %v", kid)
	}
	if adult := e.rail(e.owner); !jaContains(adult, "ja_mov") {
		t.Errorf("re-matched film missing from the Adult rail (it was re-rated, not removed): %v", adult)
	}
}

func TestTASK934_EpisodeFixBumpsChangeSeqAndDropsReRatedTitleFromKidsRail(t *testing.T) {
	e := newJAEnv(t)
	e.pcTitle("ja_ep", "lib_tv", "episode", "/tv/JaShowA/S01E01.mkv", "JaShowA", "Animation",
		time.Date(2026, 1, 1, 1, 0, 0, 0, time.UTC).Format(time.RFC3339), jaCert("TV-Y"))
	if kid := e.rail(e.kid); len(kid) != 1 {
		t.Fatalf("precondition: the TV-Y show is the Older Kids rail's one entry: %v", kid)
	}
	before := e.changeSeq("ja_ep")

	// No type: the server derives "tv" from the episode row.
	r := e.do(qaAlice, "POST", "/items/ja_ep/tmdb-fix", `{"tmdbId":601}`, e.owner)
	wantOK(t, r, 200)
	if got := e.contentRating("ja_ep"); got != "TV-MA" {
		t.Fatalf("re-match stored content_rating %q, want TV-MA", got)
	}
	e.assertSeqBumpedAndPublished("ja_ep", before)

	if kid := e.rail(e.kid); len(kid) != 0 {
		t.Errorf("TV-MA episode still on the Older Kids rail after the re-match: %v", kid)
	}
	if adult := e.rail(e.owner); len(adult) != 1 {
		t.Errorf("re-matched show missing from the Adult rail: %v", adult)
	}
}

func TestTASK934_ShowFixBumpsEveryEpisodeAndDropsShowFromKidsRail(t *testing.T) {
	e := newJAEnv(t)
	for i, ep := range []string{"ja_s1", "ja_s2"} {
		e.pcTitle(ep, "lib_tv", "episode", "/tv/JaShowB/S01E0"+string(rune('1'+i))+".mkv", "JaShowB", "Animation",
			time.Date(2026, 1, 1, 2, i, 0, 0, time.UTC).Format(time.RFC3339), jaCert("TV-Y"))
	}
	if kid := e.rail(e.kid); len(kid) != 1 {
		t.Fatalf("precondition: the TV-Y show is the Older Kids rail's one entry: %v", kid)
	}
	b1, b2 := e.changeSeq("ja_s1"), e.changeSeq("ja_s2")

	r := e.do(qaAlice, "POST", "/tv/shows/JaShowB/tmdb-fix", `{"tmdbId":701}`, e.owner)
	wantOK(t, r, 200)
	for _, ep := range []string{"ja_s1", "ja_s2"} {
		if got := e.contentRating(ep); got != "TV-MA" {
			t.Fatalf("%s: show re-match stored content_rating %q, want TV-MA", ep, got)
		}
	}
	e.assertSeqBumpedAndPublished("ja_s1", b1)
	e.assertSeqBumpedAndPublished("ja_s2", b2)

	if kid := e.rail(e.kid); len(kid) != 0 {
		t.Errorf("TV-MA show still on the Older Kids rail after the show re-match: %v", kid)
	}
	if adult := e.rail(e.owner); len(adult) != 1 {
		t.Errorf("re-matched show missing from the Adult rail: %v", adult)
	}
}

func TestTASK934_ItemFixOnUnknownIDIsNotFoundAndChangesNothing(t *testing.T) {
	e := newJAEnv(t)
	e.pcMovie("ja_mov", jaCert("G"), 50)
	seqBefore := e.s.cachedItemSeq.Load()
	r := e.do(qaAlice, "POST", "/items/ja_nope/tmdb-fix", `{"tmdbId":501,"type":"movie"}`, e.owner)
	wantErr(t, r, 404, "not_found")
	if got := e.s.cachedItemSeq.Load(); got != seqBefore {
		t.Errorf("a refused fix published item_seq %d -> %d", seqBefore, got)
	}
	if e.count(`SELECT COUNT(*) FROM items WHERE id = 'ja_nope'`) != 0 {
		t.Errorf("a fix on an unknown id created a row")
	}
}

func TestTASK934_CompletedScanInvalidatesTheRail(t *testing.T) {
	e := newJAEnv(t)
	e.pcMovie("ja_mov", jaCert("G"), 50)
	if !jaContains(e.rail(e.kid), "ja_mov") {
		t.Fatalf("precondition: G film on the Older Kids rail")
	}
	// A write that changes the rating without touching item_seq (what a scan's own writes
	// look like to the cache before it ends).
	if _, err := e.db.Exec(`UPDATE items SET content_rating = 'R' WHERE id = 'ja_mov'`); err != nil {
		t.Fatal(err)
	}
	if !jaContains(e.rail(e.kid), "ja_mov") {
		t.Fatalf("precondition: the cached rail still holds the pre-change answer (else this test proves nothing)")
	}
	e.s.cfg.TVPath = t.TempDir() // a real, readable, empty library: the scan completes
	if err := e.s.scanAllWithClient(context.Background(), nil); err != nil {
		t.Fatalf("scan: %v", err)
	}
	if kid := e.rail(e.kid); jaContains(kid, "ja_mov") {
		t.Errorf("R film still on the Older Kids rail after a completed scan: %v", kid)
	}
}

func TestTASK934_UnknownLibraryOnAFreshCacheDoesNotRecompute(t *testing.T) {
	e := newJAEnv(t)
	e.pcMovie("ja_mov", jaCert("G"), 50)
	e.rail(e.kid) // warm
	e.s.justAdded.mu.RLock()
	warmAt := e.s.justAdded.computedAt
	e.s.justAdded.mu.RUnlock()
	if warmAt.IsZero() {
		t.Fatalf("precondition: cache computed")
	}

	r := e.do(qaAlice, "GET", "/just-added?libraryId=lib_nope", "", e.kid)
	wantOK(t, r, 200)
	if items, _ := r.js["items"].([]any); len(items) != 0 {
		t.Errorf("unknown library served items: %s", r.raw)
	}
	e.s.justAdded.mu.RLock()
	after := e.s.justAdded.computedAt
	e.s.justAdded.mu.RUnlock()
	if !after.Equal(warmAt) {
		t.Errorf("an unknown libraryId recomputed the rails (computedAt %v -> %v)", warmAt, after)
	}
}

// lockedBuf is a log sink safe for concurrent writers and a reader.
type lockedBuf struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (l *lockedBuf) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Write(p)
}

func (l *lockedBuf) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.String()
}

func TestTASK934_ConcurrentMissesRunOneRefresh(t *testing.T) {
	e := newJAEnv(t)
	for i := 0; i < 40; i++ {
		e.pcMovie("ja_m"+string(rune('a'+i%26))+string(rune('a'+i/26)), jaCert("PG"), i)
	}
	e.s.justAdded.invalidate() // stale: never computed

	var sink lockedBuf
	log.SetOutput(&sink)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })

	const callers = 32
	start := make(chan struct{})
	var wg sync.WaitGroup
	for i := 0; i < callers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			e.s.ensureJustAddedFresh()
		}()
	}
	close(start)
	wg.Wait()

	if n := strings.Count(sink.String(), "[justAdded] refreshed"); n != 1 {
		t.Errorf("%d concurrent misses ran %d refreshes, want exactly 1", callers, n)
	}
	// And every caller came back to a usable cache.
	if kid := e.rail(e.kid); len(kid) == 0 {
		t.Errorf("rail empty after the shared refresh")
	}
}
