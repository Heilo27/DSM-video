package main

import (
	"database/sql"
	"log"
	"net/http"
	"path/filepath"
	"strings"
	"sync"
	"time"
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
// The cache is ALSO refreshed on demand when it is empty or older than this, so a freshly
// started server answers correctly without waiting for the first tick.
const justAddedRefreshInterval = 12 * time.Hour

// justAddedCache holds the precomputed rail, per library.
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
type justAddedCache struct {
	mu         sync.RWMutex
	byLibrary  map[string][]map[string]any
	computedAt time.Time
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
	// The empty key is the all-libraries rail, which is what the home screen asks for.
	for _, id := range append(libraryIDs, "") {
		rows, err := s.queryJustAdded(id)
		if err != nil {
			log.Printf("[justAdded] compute failed for library %q: %v", id, err)
			continue
		}
		next[id] = rows
	}

	s.justAdded.mu.Lock()
	s.justAdded.byLibrary = next
	s.justAdded.computedAt = time.Now()
	s.justAdded.mu.Unlock()
	log.Printf("[justAdded] refreshed %d librar(ies)", len(next))
}

// queryJustAdded computes the newest titles for one library, or all when libraryID is "".
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
func (s *Server) queryJustAdded(libraryID string) ([]map[string]any, error) {
	where := "WHERE i.added_at != ''"
	var args []any
	if libraryID != "" {
		where += " AND i.library_id = ?"
		args = append(args, libraryID)
	}

	// Over-fetch, then dedup: the dedup is by show and cannot be expressed as a LIMIT.
	// 500 is far more than enough to find 24 distinct titles even in an episode-heavy week.
	args = append(args, 500)
	rows, err := s.db.Query(`
		SELECT i.id, i.type, i.title, i.year, i.duration_seconds, i.added_at, i.rating,
		       i.poster_path, i.backdrop_path, i.show_name, i.season_number, i.episode_number,
		       i.library_id, i.path
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
	}
	tvRoot := filepath.Clean(s.cfg.TVPath) + "/"
	var cands []candidate
	nameCounts := map[string]map[string]int{}
	for rows.Next() {
		var c candidate
		var path string
		if err := rows.Scan(&c.id, &c.typ, &c.title, &c.year, &c.duration, &c.addedAt,
			&c.rating, &c.posterPath, &c.backdropPath, &c.showName, &c.season, &c.episode,
			&c.libID, &path); err != nil {
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

// handleJustAdded serves the precomputed rail.
//
// Answers from cache, and recomputes on demand when the cache is empty or stale — so a
// server that has just started, or one whose library changed since the last tick, still
// gives a correct answer rather than an old one. The client no longer decides what is new.
func (s *Server) handleJustAdded(w http.ResponseWriter, r *http.Request) {
	libraryID := strings.TrimSpace(r.URL.Query().Get("libraryId"))
	limit := clampInt(parseInt(r.URL.Query().Get("limit"), 16), 1, justAddedCacheSize)

	s.justAdded.mu.RLock()
	items, ok := s.justAdded.byLibrary[libraryID]
	age := time.Since(s.justAdded.computedAt)
	s.justAdded.mu.RUnlock()

	if !ok || age > justAddedRefreshInterval {
		s.refreshJustAdded()
		s.justAdded.mu.RLock()
		items = s.justAdded.byLibrary[libraryID]
		s.justAdded.mu.RUnlock()
	}

	if len(items) > limit {
		items = items[:limit]
	}
	if items == nil {
		items = []map[string]any{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}
