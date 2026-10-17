package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"

	"dsvideo/backend/internal/metadata"
)

// TASK-915: content-rating / studio / keyword backfill.
//
// New scans store the US certification, production companies, networks and keywords as part
// of the detail call they already make. This worker covers the library that was enriched
// BEFORE that existed: rows with metadata_fetched_at set but tmdb_extras_checked_at NULL.
//
// Constraints it is built around (this runs on a NAS, against a metered third-party API):
//
//   - One TMDb request per movie and two per SHOW (search + detail), not per episode: every
//     episode of a show takes the show's rating and tags, so a 300-episode series costs two
//     requests, not 300. The detail call is made WITHOUT credits, with release_dates /
//     content_ratings and keywords appended.
//   - Paced. One unit of work per contentRatingBackfillPace, never a burst.
//   - Not at startup. It waits contentRatingBackfillStartDelay, and it also stands down while a
//     scan is running (the scan is already hitting TMDb with a worker pool) and holds a
//     metaSemaphore slot like any other TMDb caller.
//   - Resumable with no state of its own: progress IS the database. A row leaves the queue when
//     tmdb_extras_checked_at is stamped, so a restart picks up exactly where the last run
//     stopped.
//   - Terminates per title. A title TMDb answered for but that has no US certification gets
//     tmdb_extras_checked_at stamped with content_rating left NULL ("unrated"), so it is never
//     asked about again. A 404 is stamped the same way. Transient failures (network, 429, 5xx,
//     a bad API key) are NOT stamped — they back off, and after contentRatingBackfillMaxFailures
//     consecutive failures on one unit the unit is skipped for the rest of this process run, so
//     one poisoned title cannot block the queue behind it.
//
// Timing knobs. Variables, not constants, only so tests can run the real loop in milliseconds;
// nothing in production writes them.
var (
	contentRatingBackfillStartDelay  = 3 * time.Minute
	contentRatingBackfillPace        = 1500 * time.Millisecond
	contentRatingBackfillIdle        = time.Hour
	contentRatingBackfillBackoffBase = 30 * time.Second
	contentRatingBackfillBackoffMax  = 15 * time.Minute
)

const (
	contentRatingBackfillMaxFailures = 5
	// Rows rewritten per transaction. A long-running show can have hundreds of episodes; one
	// transaction over all of them would hold SQLite's single write lock against playback
	// progress writes for the duration.
	contentRatingBackfillTxChunk = 100
)

// ratingUnit is one TMDb lookup's worth of work: a single movie, or every unrated episode of
// one show.
type ratingUnit struct {
	key      string // stable identity for the in-process skip list
	movieID  int    // TMDb movie id; 0 for a show unit
	showName string
	showYear sql.NullInt64
	itemIDs  []string
}

func (u ratingUnit) isMovie() bool { return u.movieID > 0 }

// nullableString maps "" to SQL NULL. For content ratings NULL means "unrated", never "".
func nullableString(v string) sql.NullString {
	if v == "" {
		return sql.NullString{}
	}
	return sql.NullString{String: v, Valid: true}
}

// startContentRatingBackfill launches the background worker. It returns immediately.
func (s *Server) startContentRatingBackfill(ctx context.Context) {
	go s.runContentRatingBackfill(ctx)
}

func (s *Server) runContentRatingBackfill(ctx context.Context) {
	if !sleepCtx(ctx, contentRatingBackfillStartDelay) {
		return
	}
	skipped := map[string]bool{}
	failures := 0
	var lastKey string
	for {
		if ctx.Err() != nil {
			return
		}
		s.tmdbMu.RLock()
		client := s.tmdbClient
		s.tmdbMu.RUnlock()
		// No key configured (it can be set at runtime), or a scan is mid-flight: wait it out.
		if client == nil || s.scanInProgress.Load() {
			if !sleepCtx(ctx, contentRatingBackfillPace*4) {
				return
			}
			continue
		}

		unit, ok, err := s.nextRatingUnit(ctx, skipped)
		if err != nil {
			log.Printf("content-rating backfill: select next unit: %v", err)
			if !sleepCtx(ctx, contentRatingBackfillBackoffMax) {
				return
			}
			continue
		}
		if !ok {
			// Queue empty. Check again later rather than exiting: a TMDb key added at runtime or
			// an admin metadata refresh can make new rows eligible.
			if !sleepCtx(ctx, contentRatingBackfillIdle) {
				return
			}
			continue
		}

		if unit.key != lastKey {
			failures = 0
			lastKey = unit.key
		}
		s.metaSemaphore <- struct{}{}
		perr := s.processRatingUnit(ctx, client, unit)
		<-s.metaSemaphore
		if perr != nil {
			failures++
			if failures >= contentRatingBackfillMaxFailures {
				skipped[unit.key] = true
				log.Printf("content-rating backfill: giving up on %s for this run after %d failures: %v", unit.key, failures, perr)
				failures = 0
				lastKey = ""
				continue
			}
			wait := contentRatingBackfillBackoffBase << (failures - 1)
			if wait > contentRatingBackfillBackoffMax {
				wait = contentRatingBackfillBackoffMax
			}
			log.Printf("content-rating backfill: %s failed (%d/%d), retrying in %s: %v",
				unit.key, failures, contentRatingBackfillMaxFailures, wait, perr)
			if !sleepCtx(ctx, wait) {
				return
			}
			continue
		}
		failures = 0
		if !sleepCtx(ctx, contentRatingBackfillPace) {
			return
		}
	}
}

// sleepCtx waits d or until ctx is cancelled. It reports whether the full wait elapsed.
func sleepCtx(ctx context.Context, d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-t.C:
		return true
	}
}

// Eligibility, shared by both unit queries: enriched, and extras never fetched.
const ratingBackfillEligible = `metadata_fetched_at IS NOT NULL
	AND tmdb_extras_checked_at IS NULL`

// nextRatingUnit picks the next lookup to perform, skipping keys in `skipped`. ok=false means
// the queue is empty.
func (s *Server) nextRatingUnit(ctx context.Context, skipped map[string]bool) (ratingUnit, bool, error) {
	// Movies first: one cheap request each, and tmdb_id is reliably the MOVIE id for them.
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, tmdb_id FROM items
		WHERE type = 'movie' AND tmdb_id > 0 AND `+ratingBackfillEligible+`
		ORDER BY id LIMIT 50`)
	if err != nil {
		return ratingUnit{}, false, fmt.Errorf("query movies: %w", err)
	}
	for rows.Next() {
		var id string
		var tmdbID int
		if err := rows.Scan(&id, &tmdbID); err != nil {
			rows.Close()
			return ratingUnit{}, false, fmt.Errorf("scan movie row: %w", err)
		}
		key := "movie:" + id
		if skipped[key] {
			continue
		}
		rows.Close()
		return ratingUnit{key: key, movieID: tmdbID, itemIDs: []string{id}}, true, nil
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return ratingUnit{}, false, fmt.Errorf("iterate movies: %w", err)
	}
	rows.Close()

	// Episodes are grouped by show. tmdb_id is NOT usable here: for an episode it holds the
	// EPISODE's TMDb id (or 0, or a show id after a manual show fix), never reliably the show's.
	// show_name is TMDb's canonical show title, written at enrichment, and year is the show's
	// first-air year, so (show_name, year) identifies the show well enough to search for.
	srows, err := s.db.QueryContext(ctx, `
		SELECT DISTINCT show_name, year FROM items
		WHERE type = 'episode' AND show_name IS NOT NULL AND show_name <> '' AND `+ratingBackfillEligible+`
		ORDER BY show_name, year LIMIT 50`)
	if err != nil {
		return ratingUnit{}, false, fmt.Errorf("query shows: %w", err)
	}
	type showKey struct {
		name string
		year sql.NullInt64
	}
	var candidates []showKey
	for srows.Next() {
		var k showKey
		if err := srows.Scan(&k.name, &k.year); err != nil {
			srows.Close()
			return ratingUnit{}, false, fmt.Errorf("scan show row: %w", err)
		}
		candidates = append(candidates, k)
	}
	if err := srows.Err(); err != nil {
		srows.Close()
		return ratingUnit{}, false, fmt.Errorf("iterate shows: %w", err)
	}
	srows.Close()

	for _, k := range candidates {
		key := fmt.Sprintf("show:%s|%d", k.name, k.year.Int64)
		if skipped[key] {
			continue
		}
		idRows, err := s.db.QueryContext(ctx, `
			SELECT id FROM items
			WHERE type = 'episode' AND show_name = ? AND year IS ? AND `+ratingBackfillEligible, k.name, k.year)
		if err != nil {
			return ratingUnit{}, false, fmt.Errorf("query episodes of %q: %w", k.name, err)
		}
		var ids []string
		for idRows.Next() {
			var id string
			if err := idRows.Scan(&id); err != nil {
				idRows.Close()
				return ratingUnit{}, false, fmt.Errorf("scan episode id: %w", err)
			}
			ids = append(ids, id)
		}
		if err := idRows.Err(); err != nil {
			idRows.Close()
			return ratingUnit{}, false, fmt.Errorf("iterate episodes of %q: %w", k.name, err)
		}
		idRows.Close()
		if len(ids) == 0 {
			continue
		}
		return ratingUnit{key: key, showName: k.name, showYear: k.year, itemIDs: ids}, true, nil
	}
	return ratingUnit{}, false, nil
}

// processRatingUnit asks TMDb and records the answer. A nil return means the unit is finished
// (rated, or recorded as checked-with-no-US-cert) and must not be selected again; a non-nil
// return means nothing was recorded and the unit stays in the queue.
func (s *Server) processRatingUnit(ctx context.Context, client *metadata.TMDbClient, u ratingUnit) error {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	var extras metadata.Extras
	var err error
	if u.isMovie() {
		extras, err = client.GetMovieExtras(ctx, u.movieID)
	} else {
		extras, err = lookupShowExtras(ctx, client, u.showName, u.showYear)
	}
	if err != nil {
		var apiErr *metadata.APIError
		if errors.As(err, &apiErr) && apiErr.Status == http.StatusNotFound {
			// TMDb no longer has this title. Permanent: record the check, leave it unrated.
			log.Printf("content-rating backfill: %s not found on TMDb, recording as checked/unrated", u.key)
			extras = metadata.Extras{}
		} else {
			return err
		}
	}
	return s.recordExtras(ctx, u.itemIDs, extras)
}

// lookupShowExtras resolves a stored show to a TMDb show and returns its extras.
//
// The search result must match the stored name exactly (case-insensitive, on name or original
// name). Taking results[0] on a mismatch would hand a family-friendly show the rating of an
// unrelated one; "no match" instead resolves to empty extras, i.e. unrated, an honest answer.
func lookupShowExtras(ctx context.Context, client *metadata.TMDbClient, name string, year sql.NullInt64) (metadata.Extras, error) {
	y := 0
	if year.Valid {
		y = int(year.Int64)
	}
	results, err := client.SearchTV(ctx, name, y)
	if err != nil {
		return metadata.Extras{}, err
	}
	for _, r := range results {
		if strings.EqualFold(r.Name, name) || strings.EqualFold(r.OriginalName, name) {
			return client.GetTVExtras(ctx, r.ID)
		}
	}
	log.Printf("content-rating backfill: no TMDb show matches %q (%d); recording as unrated", name, y)
	return metadata.Extras{}, nil
}

// recordExtras writes the answer for a unit's rows. A non-empty rating sets content_rating and
// bumps change_seq (clients only learn of a changed row through delta sync, which asks for
// change_seq > cursor — the same reason enrichment allocates one). With no rating only the
// checked stamp is written: nothing the client can see changed, so no sequence is spent.
// Studio and keyword tags are server-side only and never need a sequence.
//
// tmdb_extras_checked_at IS NULL guards every UPDATE so a row the scanner enriched in the
// meantime is never overwritten with an older answer.
func (s *Server) recordExtras(ctx context.Context, ids []string, extras metadata.Extras) error {
	now := time.Now().UTC().Format(time.RFC3339)
	for start := 0; start < len(ids); start += contentRatingBackfillTxChunk {
		end := start + contentRatingBackfillTxChunk
		if end > len(ids) {
			end = len(ids)
		}
		var maxSeq int64
		tx, err := s.db.BeginTx(ctx, nil)
		if err != nil {
			return fmt.Errorf("begin: %w", err)
		}
		for _, id := range ids[start:end] {
			var seq int64
			var res sql.Result
			if extras.ContentRating == "" {
				res, err = tx.ExecContext(ctx,
					`UPDATE items SET tmdb_extras_checked_at = ? WHERE id = ? AND tmdb_extras_checked_at IS NULL`,
					now, id)
			} else {
				if err = allocItemSeqTx(ctx, tx, &seq); err != nil || seq <= 0 {
					_ = tx.Rollback()
					return fmt.Errorf("allocate change_seq for %s: %v", id, err)
				}
				res, err = tx.ExecContext(ctx, `
					UPDATE items SET content_rating = ?, tmdb_extras_checked_at = ?, change_seq = ?
					WHERE id = ? AND tmdb_extras_checked_at IS NULL`, extras.ContentRating, now, seq, id)
			}
			if err != nil {
				_ = tx.Rollback()
				return fmt.Errorf("write extras %s: %w", id, err)
			}
			if n, _ := res.RowsAffected(); n == 0 {
				// Enriched by someone else since we selected it; give the sequence back so an
				// untouched row does not advance every client's cursor.
				if seq > 0 {
					_, _ = tx.ExecContext(ctx,
						`UPDATE sync_state SET value = value - 1 WHERE key = 'item_seq' AND value = ?`, seq)
				}
				continue
			}
			if err := replaceItemTags(ctx, tx, id, extras); err != nil {
				_ = tx.Rollback()
				return fmt.Errorf("write tags %s: %w", id, err)
			}
			if seq > maxSeq {
				maxSeq = seq
			}
		}
		if err := tx.Commit(); err != nil {
			return fmt.Errorf("commit: %w", err)
		}
		// Publish only after the commit — see publishItemSeq.
		s.publishItemSeq(maxSeq)
	}
	return nil
}

// replaceItemTags makes item_companies / item_keywords for itemID exactly match extras,
// inside the caller's transaction. Replace, not merge: after a manual TMDb re-match the old
// title's studios and keywords must not linger. Entries without a positive TMDb id are
// dropped (nothing could look them up), and duplicates collapse on the primary key.
func replaceItemTags(ctx context.Context, tx *sql.Tx, itemID string, extras metadata.Extras) error {
	if _, err := tx.ExecContext(ctx, `DELETE FROM item_companies WHERE item_id = ?`, itemID); err != nil {
		return fmt.Errorf("clear companies: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM item_keywords WHERE item_id = ?`, itemID); err != nil {
		return fmt.Errorf("clear keywords: %w", err)
	}
	insertCompanies := func(kind string, list []metadata.Company) error {
		for _, c := range list {
			if c.ID <= 0 {
				continue
			}
			if _, err := tx.ExecContext(ctx,
				`INSERT OR IGNORE INTO item_companies(item_id, kind, company_id, name) VALUES (?,?,?,?)`,
				itemID, kind, c.ID, strings.TrimSpace(c.Name)); err != nil {
				return fmt.Errorf("insert %s %d: %w", kind, c.ID, err)
			}
		}
		return nil
	}
	if err := insertCompanies("company", extras.Companies); err != nil {
		return err
	}
	if err := insertCompanies("network", extras.Networks); err != nil {
		return err
	}
	for _, k := range extras.Keywords {
		if k.ID <= 0 {
			continue
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT OR IGNORE INTO item_keywords(item_id, keyword_id, name) VALUES (?,?,?)`,
			itemID, k.ID, strings.TrimSpace(k.Name)); err != nil {
			return fmt.Errorf("insert keyword %d: %w", k.ID, err)
		}
	}
	return nil
}
