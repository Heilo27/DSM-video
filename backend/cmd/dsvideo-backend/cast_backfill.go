package main

import (
	"context"
	"fmt"
	"log"
	"net/http"

	"dsvideo/backend/internal/metadata"
	"dsvideo/backend/internal/sqltx"
)

// TASK-747 FR-150: cast backfill for POST /api/v1/admin/metadata/refresh?scope=cast.
//
// Titles enriched before cast photos shipped have a tmdb_id and the legacy cast_names text but
// no item_cast rows. The other refresh scopes clear metadata_fetched_at so the next scan
// re-queries TMDb BY TITLE; that would also re-match titles whose TMDb id was fixed by hand
// (tmdb-fix), silently undoing the fix. This scope instead goes BY the stored tmdb_id, so a
// manual match is only ever read, never replaced, and it writes item_cast only: no items
// column changes, which is also why it needs no change_seq (the detail endpoint reads
// item_cast live; the delta-synced summaries carry no cast).
//
// One TMDb request per distinct (kind, tmdb_id), not per episode: every episode of a show
// shares the show's id and the show's cast. It uses the same pacing knob as the content-rating
// backfill (contentRatingBackfillPace), holds a metaSemaphore slot per request like every
// other TMDb caller, and stands down while a scan runs. It is resumable with no state of its
// own: a title leaves the queue when it has item_cast rows.

// castUnit is one TMDb lookup's worth of work: a movie, or one show covering all its episodes.
type castUnit struct {
	kind   string // "movie" or "tv"
	tmdbID int
	items  int // how many of the library's items are waiting on this lookup
}

// castBackfillResult is what one run did, for the log and the tests.
type castBackfillResult struct {
	Units       int // lookups attempted
	ItemsFilled int // items that gained cast rows
	NoCast      int // lookups TMDb answered with no usable cast
	Failed      int // lookups that failed (left queued for the next run)
}

// itemKindSQL is the one place an items.type becomes the TMDb endpoint family: episodes carry
// their show's id and are TV, everything else is looked up as a movie (the same split the
// scanner and tmdb-fix use).
const itemKindSQL = `CASE WHEN type = 'episode' THEN 'tv' ELSE 'movie' END`

// pendingCastUnits lists the lookups still needed: items with a TMDb id and no cast rows.
func (s *Server) pendingCastUnits(ctx context.Context) ([]castUnit, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT `+itemKindSQL+` AS kind, tmdb_id, COUNT(*)
		FROM items i
		WHERE tmdb_id IS NOT NULL AND tmdb_id > 0
		  AND NOT EXISTS (SELECT 1 FROM item_cast c WHERE c.item_id = i.id)
		GROUP BY kind, tmdb_id
		ORDER BY kind, tmdb_id`)
	if err != nil {
		return nil, fmt.Errorf("list cast backfill units: %w", err)
	}
	defer rows.Close()
	var units []castUnit
	for rows.Next() {
		var u castUnit
		if err := rows.Scan(&u.kind, &u.tmdbID, &u.items); err != nil {
			return nil, fmt.Errorf("scan cast backfill unit: %w", err)
		}
		units = append(units, u)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate cast backfill units: %w", err)
	}
	return units, nil
}

// fetchCastMembers asks TMDb for a title's billed cast by id.
func fetchCastMembers(ctx context.Context, client *metadata.TMDbClient, u castUnit) ([]metadata.CastMember, error) {
	if u.kind == "tv" {
		d, err := client.GetTVDetails(ctx, u.tmdbID)
		if err != nil {
			return nil, err
		}
		return d.Credits.TopCast(metadata.StoredCastSize), nil
	}
	d, err := client.GetMovieDetails(ctx, u.tmdbID)
	if err != nil {
		return nil, err
	}
	return d.Credits.TopCast(metadata.StoredCastSize), nil
}

// storeCastFor writes members onto every item of u that still has no cast rows, in chunks so
// a long-running show does not hold SQLite's write lock for hundreds of rows at once. It
// returns how many items it filled.
func (s *Server) storeCastFor(ctx context.Context, u castUnit, members []metadata.CastMember) (int, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT id FROM items i
		WHERE tmdb_id = ? AND `+itemKindSQL+` = ?
		  AND NOT EXISTS (SELECT 1 FROM item_cast c WHERE c.item_id = i.id)`, u.tmdbID, u.kind)
	if err != nil {
		return 0, fmt.Errorf("list items for %s %d: %w", u.kind, u.tmdbID, err)
	}
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return 0, fmt.Errorf("scan item id: %w", err)
		}
		ids = append(ids, id)
	}
	rowsErr := rows.Err()
	rows.Close()
	if rowsErr != nil {
		return 0, fmt.Errorf("iterate items for %s %d: %w", u.kind, u.tmdbID, rowsErr)
	}

	filled := 0
	for start := 0; start < len(ids); start += contentRatingBackfillTxChunk {
		end := min(start+contentRatingBackfillTxChunk, len(ids))
		if err := s.storeCastChunk(ctx, ids[start:end], members); err != nil {
			return filled, err
		}
		filled += end - start
	}
	return filled, nil
}

func (s *Server) storeCastChunk(ctx context.Context, ids []string, members []metadata.CastMember) error {
	tx, err := sqltx.Begin(ctx, s.db)
	if err != nil {
		return fmt.Errorf("begin cast tx: %w", err)
	}
	defer tx.Close()
	for _, id := range ids {
		if err := replaceItemCast(ctx, tx.Tx, id, members); err != nil {
			return fmt.Errorf("store cast for %s: %w", id, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit cast tx: %w", err)
	}
	return nil
}

// runCastBackfill works through units one paced TMDb request at a time. A failed lookup is
// logged and skipped (it stays queued for the next run), so one bad title cannot hold up the
// rest. It stops early, with the counts so far, when ctx ends.
func (s *Server) runCastBackfill(ctx context.Context, client *metadata.TMDbClient, units []castUnit) castBackfillResult {
	var res castBackfillResult
	for _, u := range units {
		if ctx.Err() != nil {
			return res
		}
		// A scan is already hitting TMDb with its own worker pool; wait it out.
		for s.scanInProgress.Load() {
			if !sleepCtx(ctx, contentRatingBackfillPace*4) {
				return res
			}
		}
		res.Units++
		s.metaSemaphore <- struct{}{}
		members, err := fetchCastMembers(ctx, client, u)
		<-s.metaSemaphore
		if err != nil {
			res.Failed++
			log.Printf("cast backfill: %s %d: %v", u.kind, u.tmdbID, err)
		} else if len(members) == 0 {
			res.NoCast++
		} else if n, serr := s.storeCastFor(ctx, u, members); serr != nil {
			res.Failed++
			res.ItemsFilled += n
			log.Printf("cast backfill: %s %d: %v", u.kind, u.tmdbID, serr)
		} else {
			res.ItemsFilled += n
		}
		if !sleepCtx(ctx, contentRatingBackfillPace) {
			return res
		}
	}
	return res
}

// startCastBackfill answers POST /admin/metadata/refresh?scope=cast: it queues the pending
// lookups and runs them in the background, returning 202 with how much work was found. Only
// one run at a time; a second request while one is running reports started=false.
func (s *Server) startCastBackfill(w http.ResponseWriter, r *http.Request) {
	s.tmdbMu.RLock()
	client := s.tmdbClient
	s.tmdbMu.RUnlock()
	if client == nil {
		writeErr(w, http.StatusBadRequest, "tmdb_not_configured")
		return
	}
	if !s.castBackfillRunning.CompareAndSwap(false, true) {
		writeJSON(w, http.StatusAccepted, map[string]any{
			"scope": "cast", "started": false, "reason": "cast_backfill_already_running",
		})
		return
	}
	units, err := s.pendingCastUnits(r.Context())
	if err != nil {
		s.castBackfillRunning.Store(false)
		writeFailure(w, r, http.StatusInternalServerError, "db_error", err)
		return
	}
	items := 0
	for _, u := range units {
		items += u.items
	}
	if len(units) == 0 {
		s.castBackfillRunning.Store(false)
		writeJSON(w, http.StatusOK, map[string]any{
			"scope": "cast", "started": false, "reason": "nothing_to_backfill", "queued": 0, "items": 0,
		})
		return
	}
	log.Printf("[admin] cast backfill: %d lookups for %d item(s)", len(units), items)
	go func() {
		defer s.castBackfillRunning.Store(false)
		res := s.runCastBackfill(context.Background(), client, units)
		log.Printf("[admin] cast backfill done: %d lookups, %d items filled, %d without cast, %d failed",
			res.Units, res.ItemsFilled, res.NoCast, res.Failed)
	}()
	writeJSON(w, http.StatusAccepted, map[string]any{
		"scope": "cast", "started": true, "queued": len(units), "items": items,
	})
}
