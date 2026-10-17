package main

import (
	"database/sql"
	"log"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	agerating "dsvideo/backend/internal/rating"
)

// justAddedCacheSize is how many titles the rail holds.
//
// The clients render 16. Computing a few more costs nothing and means a client that filters
// (a library scope, a hidden item) still has a full rail rather than a short one.
const justAddedCacheSize = 24

// justAddedRefreshInterval is how often the library is re-polled.
//
// The rail answers "what is new", and new content arrives when a scan finishes — not
// continuously. Twice a day is the requested cadence and is the right order of magnitude:
// the query is a single indexed ORDER BY over `items`, so the cost is trivial, but there is
// no reason to pay it per request when the answer changes a handful of times a week.
//
// The timer is only the backstop. A request recomputes on demand whenever the cache is
// stale (see fresh): never computed, older than this, invalidated by a scan or a rating
// change, or behind the library's item_seq. That last one is what makes a re-rated title
// leave a kids' rail at once (FR-250): every write that changes what a client sees,
// content_rating included, takes a new change_seq, so the cache cannot outlive it.
const justAddedRefreshInterval = 12 * time.Hour

// justAddedCache holds the precomputed rail, per library and per age ceiling.
//
// WHY THE SERVER OWNS THIS
// ------------------------
// The clients used to compute Just Added themselves, from their local SQLite mirror:
// ORDER BY added_at DESC over whatever had been synced, deduplicated in Swift. That is a
// guess about the library made by the party that does NOT hold it, and it fails silently in
// the one way that matters — when the mirror stops updating, the rail keeps rendering
// confidently stale content and nothing anywhere reports a problem. That is exactly what
// happened: a phone showed the same four TV shows for days while the server held a dozen
// newer films, and four separate client-side fixes chased the symptom.
//
// The server has first-hand knowledge of its own library. It should answer the question.
//
// PER CEILING (FRD-002 FR-250)
// ----------------------------
// A restricted profile's rail is computed with its ceiling inside the query, so the dedup and
// the 24-slot cut see only visible titles and the rail is as full as the library allows.
// Trimming the shared rail afterwards would leave a kids' profile a short or empty rail
// whenever the newest additions are adult. There are only four ceilings, so every
// (ceiling, library) rail is precomputed: 4 × libraries small indexed queries per refresh.
type justAddedCache struct {
	mu         sync.RWMutex
	byLibrary  map[string][]map[string]any // key: justAddedKey(maxLevel, libraryID)
	computedAt time.Time
	// gen counts invalidations; builtGen is the gen the stored rails were computed under.
	// A refresh that was already running when invalidate() fired stores what it read but
	// stays stale, so the next request recomputes instead of trusting pre-change rows.
	gen, builtGen uint64
	// builtItemSeq is the library's item_seq when the stored rails were computed.
	builtItemSeq int64

	// flight is non-nil while an on-demand refresh runs, and is closed when it ends.
	// Concurrent misses wait on it rather than each running their own 4 × libraries
	// queries (singleflight; TASK-934).
	flightMu sync.Mutex
	flight   chan struct{}
}

// invalidate marks every cached rail stale. Safe on a nil cache (test servers build none).
func (c *justAddedCache) invalidate() {
	if c == nil {
		return
	}
	c.mu.Lock()
	c.gen++
	c.mu.Unlock()
}

// fresh reports whether the stored rails may be served as-is, given the library's current
// item_seq. Caller holds c.mu (read or write).
func (c *justAddedCache) fresh(itemSeq int64) bool {
	return !c.computedAt.IsZero() &&
		c.builtGen == c.gen &&
		itemSeq <= c.builtItemSeq &&
		time.Since(c.computedAt) <= justAddedRefreshInterval
}

func justAddedKey(maxLevel int, libraryID string) string {
	return strconv.Itoa(maxLevel) + "|" + libraryID
}

func newJustAddedCache() *justAddedCache {
	return &justAddedCache{byLibrary: map[string][]map[string]any{}}
}

// startJustAddedRefresher recomputes the rail on a timer for the life of the process.
func (s *Server) startJustAddedRefresher() {
	// Compute once at startup so the first client to ask is not the one that pays for it.
	s.refreshJustAdded()
	go func() {
		ticker := time.NewTicker(justAddedRefreshInterval)
		defer ticker.Stop()
		for range ticker.C {
			s.refreshJustAdded()
		}
	}()
}

// refreshJustAdded recomputes and stores the rail for every library.
func (s *Server) refreshJustAdded() {
	// Read the staleness markers BEFORE the queries: anything that changes after this
	// point leaves the result marked stale rather than being silently missed.
	s.justAdded.mu.RLock()
	startGen := s.justAdded.gen
	s.justAdded.mu.RUnlock()
	startSeq := s.cachedItemSeq.Load()

	libs, err := s.db.Query(`SELECT DISTINCT library_id FROM items WHERE library_id != ''`)
	if err != nil {
		log.Printf("[justAdded] library scan failed: %v", err)
		return
	}
	var libraryIDs []string
	for libs.Next() {
		var id string
		if libs.Scan(&id) == nil {
			libraryIDs = append(libraryIDs, id)
		}
	}
	libs.Close()

	next := map[string][]map[string]any{}
	failed := false
	// The empty library is the all-libraries rail, which is what the home screen asks for.
	for level := agerating.MinLevel; level <= agerating.MaxLevel; level++ {
		for _, id := range append(libraryIDs, "") {
			rows, err := s.queryJustAdded(id, level)
			if err != nil {
				log.Printf("[justAdded] compute failed for library %q, ceiling %d: %v", id, level, err)
				failed = true
				continue
			}
			next[justAddedKey(level, id)] = rows
		}
	}

	s.justAdded.mu.Lock()
	s.justAdded.byLibrary = next
	s.justAdded.computedAt = time.Now()
	if failed {
		// Serve what was computed, but stay stale so the next request retries the rest
		// instead of serving a missing rail as empty for 12 hours.
		s.justAdded.computedAt = time.Time{}
	}
	s.justAdded.builtGen = startGen
	s.justAdded.builtItemSeq = startSeq
	s.justAdded.mu.Unlock()
	log.Printf("[justAdded] refreshed %d librar(ies) at %d ceilings", len(libraryIDs)+1, agerating.MaxLevel-agerating.MinLevel+1)
}

// queryJustAdded computes the newest titles for one library, or all when libraryID is "",
// leaving out titles above maxLevel (FR-250; agerating.MaxLevel filters nothing).
//
// Deduplicated by SHOW, not by item: a TV show that just gained twelve episodes is ONE new
// thing on the rail, not twelve. Without this a single season import buries every film the
// user added the same week — which is precisely what the clients' rails looked like.
//
// The grouping is the codebase's ONE answer for "which show is this episode part of":
// showFolderFromPath → resolveFolderShowNames → showGroupKey, the same three calls the
// list endpoints make. This rail originally keyed episodes on their own title, which is
// the one thing that is NOT stable across a show's episodes — an unmatched import whose
// show_name is NULL gave every episode a distinct key and nine of the rail's 24 slots went
// to one anime series. The folder is what those episodes actually share.
func (s *Server) queryJustAdded(libraryID string, maxLevel int) ([]map[string]any, error) {
	where := "WHERE i.added_at != ''"
	var args []any
	if libraryID != "" {
		where += " AND i.library_id = ?"
		args = append(args, libraryID)
	}
	// In the WHERE, before the over-fetch LIMIT and the dedup, never after (see justAddedCache).
	if clause, cargs := agerating.Visible("i.content_rating", maxLevel); clause != "" {
		where += " AND " + clause
		args = append(args, cargs...)
	}

	// Over-fetch, then dedup: the dedup is by show and cannot be expressed as a LIMIT.
	// 500 is far more than enough to find 24 distinct titles even in an episode-heavy week.
	args = append(args, 500)
	rows, err := s.db.Query(`
		SELECT i.id, i.type, i.title, i.year, i.duration_seconds, i.added_at, i.rating,
		       i.poster_path, i.backdrop_path, i.show_name, i.season_number, i.episode_number,
		       i.library_id, i.path, i.content_rating
		FROM items i
		`+where+`
		ORDER BY i.added_at DESC
		LIMIT ?`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	// Pass 1: read every candidate, and count show names per folder as we go.
	type candidate struct {
		id, typ, title, addedAt, libID, folder string
		year, duration, season, episode        sql.NullInt64
		rating                                 sql.NullFloat64
		posterPath, backdropPath, showName     sql.NullString
		contentRating                          *string
	}
	tvRoot := filepath.Clean(s.cfg.TVPath) + "/"
	var cands []candidate
	nameCounts := map[string]map[string]int{}
	for rows.Next() {
		var c candidate
		var path string
		if err := rows.Scan(&c.id, &c.typ, &c.title, &c.year, &c.duration, &c.addedAt,
			&c.rating, &c.posterPath, &c.backdropPath, &c.showName, &c.season, &c.episode,
			&c.libID, &path, &c.contentRating); err != nil {
			continue
		}
		if c.typ == "episode" {
			c.folder = showFolderFromPath(path, tvRoot)
			if c.folder != "" {
				if nameCounts[c.folder] == nil {
					nameCounts[c.folder] = map[string]int{}
				}
				if c.showName.Valid && c.showName.String != "" {
					nameCounts[c.folder][c.showName.String]++
				}
			}
		}
		cands = append(cands, c)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// One name per folder, so a part-matched folder does not split into two shows.
	folderNames := resolveFolderShowNames(nameCounts)

	// Pass 2: emit newest-first, one entry per show.
	out := make([]map[string]any, 0, justAddedCacheSize)
	seenShows := map[string]bool{}
	for _, c := range cands {
		id, typ, title, addedAt, libID := c.id, c.typ, c.title, c.addedAt, c.libID
		year, duration, seasonNumber, episodeNumber := c.year, c.duration, c.season, c.episode
		rating := c.rating
		posterPath, backdropPath := c.posterPath, c.backdropPath

		// The FOLDER's resolved name, not this episode's — an unmatched episode groups
		// with its siblings rather than forming a show of its own.
		showName := c.showName
		var key string
		if typ == "episode" && c.folder != "" {
			showName = folderNames[c.folder]
			key = "tv|" + showGroupKey(c.folder, showName)
		} else {
			// A film is its own show.
			key = strings.ToLower(title) + "|" + typ
		}
		if seenShows[key] {
			continue
		}
		seenShows[key] = true

		// The rail's unit is the SHOW, so an episode row is labelled with its show. The
		// episode's own title names one file ("… Episode 12 Destiny Bond") and reads as
		// noise next to film titles; the folder is the honest label when nothing matched.
		display := title
		if typ == "episode" {
			if showName.Valid && showName.String != "" {
				display = showName.String
			} else if c.folder != "" {
				display = c.folder
			}
		}

		item := map[string]any{
			"id":              id,
			"type":            typ,
			"title":           display,
			"year":            nullIntToAny(year),
			"durationSeconds": nullIntToAny(duration),
			"addedAt":         addedAt,
			"rating":          nullFloatToAny(rating),
			"libraryId":       libID,
			"posterImageId":   nil,
			"backdropImageId": nil,
			// ProfilesAPI.md "Item fields": unrated is null / level 4 (FR-242).
			"contentRating": c.contentRating,
			"ageLevel":      agerating.LevelPtr(c.contentRating),
		}
		if posterPath.Valid && posterPath.String != "" {
			item["posterImageId"] = id
		}
		if backdropPath.Valid && backdropPath.String != "" {
			item["backdropImageId"] = id
		}
		if showName.Valid && showName.String != "" {
			item["showName"] = showName.String
		}
		if seasonNumber.Valid {
			item["seasonNumber"] = seasonNumber.Int64
		}
		if episodeNumber.Valid {
			item["episodeNumber"] = episodeNumber.Int64
		}
		out = append(out, item)

		if len(out) >= justAddedCacheSize {
			break
		}
	}
	return out, nil
}

// ensureJustAddedFresh recomputes the rails if they are stale, running at most one refresh
// at a time. A caller that finds a refresh already running waits for it and then checks
// again, because that refresh may have started before the change the caller must see.
// Bounded so a write storm (the backfill re-rating titles) cannot pin a request here.
func (s *Server) ensureJustAddedFresh() {
	c := s.justAdded
	for attempt := 0; attempt < 3; attempt++ {
		c.mu.RLock()
		ok := c.fresh(s.cachedItemSeq.Load())
		c.mu.RUnlock()
		if ok {
			return
		}
		c.flightMu.Lock()
		if wait := c.flight; wait != nil {
			c.flightMu.Unlock()
			<-wait
			continue
		}
		// Re-check under flightMu: a refresh can finish between the check above and here,
		// and the leader clears c.flight only after storing its result.
		c.mu.RLock()
		ok = c.fresh(s.cachedItemSeq.Load())
		c.mu.RUnlock()
		if ok {
			c.flightMu.Unlock()
			return
		}
		done := make(chan struct{})
		c.flight = done
		c.flightMu.Unlock()

		s.refreshJustAdded()

		c.flightMu.Lock()
		c.flight = nil
		c.flightMu.Unlock()
		close(done)
	}
}

// handleJustAdded serves the precomputed rail.
//
// Answers from cache, recomputing first when the cache is stale (see justAddedCache.fresh):
// never computed, past the 12-hour backstop, invalidated by a finished scan or a TMDb
// re-match, or behind the library's item_seq. A libraryId the cache does not hold, on a
// fresh cache, is simply an empty rail; it no longer forces a recompute per request. The
// client no longer decides what is new.
func (s *Server) handleJustAdded(w http.ResponseWriter, r *http.Request) {
	libraryID := strings.TrimSpace(r.URL.Query().Get("libraryId"))
	limit := clampInt(parseInt(r.URL.Query().Get("limit"), 16), 1, justAddedCacheSize)
	// The viewing profile picks which precomputed rail is served (FR-250).
	v, ok := s.requestViewer(w, r)
	if !ok {
		return
	}
	key := justAddedKey(v.MaxAgeLevel, libraryID)

	s.ensureJustAddedFresh()
	s.justAdded.mu.RLock()
	items := s.justAdded.byLibrary[key]
	s.justAdded.mu.RUnlock()

	if len(items) > limit {
		items = items[:limit]
	}
	if items == nil {
		items = []map[string]any{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}
