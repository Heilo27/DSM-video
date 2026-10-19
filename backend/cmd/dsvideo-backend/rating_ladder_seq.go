package main

// FRD-002 FR-244: a ladder change reaches devices.
//
// Age levels are not stored per item; every read computes them from items.content_rating
// through internal/rating. So when a release edits the ladder, nothing in the items table
// changes, change_seq stays put, and a device's delta sync never re-sends the titles whose
// level moved: its offline filter keeps the old level.
//
// The fix records the level mapping the database last served (rating.Levels, as canonical
// text plus its SHA-256 fingerprint) and reconciles at startup, before the first scan:
//
//   - no record:  a database that predates this table. The ladder (certification to level)
//     has not changed since ageLevel first shipped, but the era rules (FR-241a) are newer
//     than the table: devices hold the levels the ladder alone gives. So the stored
//     mapping is taken to be the live ladder without its era rules, and the next case
//     applies: a database with no pre-1985 PG film bumps nothing.
//   - same print: nothing to do.
//   - different:  compute every item's level under the stored mapping and under the live
//     one, and give each item whose level differs a new change_seq. One item_seq value
//     covers the batch (sync pages by change_seq then rowid, so shared values page
//     correctly), and the new record is written in the same transaction, so a crash
//     leaves either the old record and no bumps (the next start redoes it) or both.
//     If no item moved, the record is updated without allocating a sequence value, so
//     devices are not sent an empty delta.
//   - stored mapping unreadable: which items moved cannot be known, so every item is bumped.
//
// A level depends on the title's type and year as well as its certification (FR-241a), so the
// comparison runs rating.Levels.ItemLevel over (content_rating, type, year). The era rules are
// part of the recorded mapping, so adding or editing one moves the fingerprint and re-sequences
// exactly the titles whose level changed, once, in this same pass. This is the one-time
// recompute for the pre-1985 PG rule: nothing else gates it.
//
// Ordering against the FR-246 heal (sync_heal.go): both run at startup before the scanner. The
// heal gives every item a fresh change_seq and advances item_seq; this pass then allocates the
// next item_seq value from the database counter and stamps only the moved titles with it. Run
// in either order a stale device receives every moved title with its new level, because the
// heal re-sends everything and this pass only ever raises a title's change_seq. Their markers
// are independent (sync_heals.name versus rating_ladder_state), so each runs once.

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"time"

	"dsvideo/backend/internal/rating"
)

// migrateRatingLadderState creates the one-row record of the ladder the database last
// served. Additive: a new table, nothing existing touched.
func migrateRatingLadderState(db *sql.DB) error {
	_, err := db.Exec(`
CREATE TABLE IF NOT EXISTS rating_ladder_state (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  fingerprint TEXT NOT NULL,
  levels TEXT NOT NULL,
  updated_at TEXT NOT NULL
);`)
	if err != nil {
		return fmt.Errorf("create rating_ladder_state: %w", err)
	}
	return nil
}

// ladderReconcileResult reports what reconcileRatingLadder did, for the log line and tests.
type ladderReconcileResult struct {
	Baseline bool  // no record existed; the live ladder was recorded, nothing bumped
	Changed  bool  // the stored fingerprint differed from the live one
	Bumped   int   // items given a new change_seq
	Seq      int64 // the change_seq they received (0 when none were bumped)
}

// reconcileRatingLadder brings the stored ladder record up to the live ladder, bumping
// change_seq for every item whose level moved (see the file comment). A failure leaves
// the old record in place, so the next start retries.
func (s *Server) reconcileRatingLadder(ctx context.Context) (ladderReconcileResult, error) {
	live := rating.CurrentLevels()
	liveFP := live.Fingerprint()

	var storedFP, storedText string
	var baseline bool
	var stored rating.Levels
	var decodeErr error
	err := s.db.QueryRowContext(ctx,
		`SELECT fingerprint, levels FROM rating_ladder_state WHERE id = 1`).Scan(&storedFP, &storedText)
	switch {
	case err == sql.ErrNoRows:
		// Devices hold what a server without the era rules served: the ladder alone.
		baseline, stored = true, live.WithoutEra()
	case err != nil:
		return ladderReconcileResult{}, fmt.Errorf("read rating_ladder_state: %w", err)
	case storedFP == liveFP:
		return ladderReconcileResult{}, nil
	default:
		stored, decodeErr = rating.DecodeLevels(storedText)
		if decodeErr != nil {
			log.Printf("[rating] stored ladder unreadable (%v): every item will be re-sent", decodeErr)
		}
	}

	moved, err := itemsWhoseLevelMoved(ctx, s.db, stored, live, decodeErr != nil)
	if err != nil {
		return ladderReconcileResult{}, err
	}
	res := ladderReconcileResult{Baseline: baseline, Changed: !baseline, Bumped: len(moved)}
	if len(moved) == 0 {
		return res, storeLadderState(ctx, s.db, live)
	}

	seq, err := s.writeWithItemSeq(ctx, func(tx *sql.Tx, seq int64) error {
		stmt, err := tx.PrepareContext(ctx, `UPDATE items SET change_seq = ? WHERE id = ?`)
		if err != nil {
			return err
		}
		defer stmt.Close()
		for _, id := range moved {
			if _, err := stmt.ExecContext(ctx, seq, id); err != nil {
				return fmt.Errorf("bump %s: %w", id, err)
			}
		}
		return storeLadderState(ctx, tx, live)
	})
	if err != nil {
		return ladderReconcileResult{}, fmt.Errorf("bump items for ladder change: %w", err)
	}
	res.Seq = seq
	return res, nil
}

// itemsWhoseLevelMoved returns the ids of items whose level differs between the stored
// and live mappings, or every item when all is set (the stored mapping is unknown).
// It reads only (id, content_rating, type, year), once, outside any write transaction.
func itemsWhoseLevelMoved(ctx context.Context, db *sql.DB, stored, live rating.Levels, all bool) ([]string, error) {
	rows, err := db.QueryContext(ctx, `SELECT id, content_rating, type, year FROM items`)
	if err != nil {
		return nil, fmt.Errorf("read item ratings: %w", err)
	}
	defer rows.Close()
	var moved []string
	for rows.Next() {
		var id, itemType string
		var cert sql.NullString
		var year sql.NullInt64
		if err := rows.Scan(&id, &cert, &itemType, &year); err != nil {
			return nil, fmt.Errorf("scan item rating: %w", err)
		}
		var c *string
		if cert.Valid {
			c = &cert.String
		}
		var y *int
		if year.Valid {
			v := int(year.Int64)
			y = &v
		}
		if all || stored.ItemLevel(c, itemType, y) != live.ItemLevel(c, itemType, y) {
			moved = append(moved, id)
		}
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read item ratings: %w", err)
	}
	return moved, nil
}

// execer is satisfied by *sql.DB and *sql.Tx.
type execer interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
}

func storeLadderState(ctx context.Context, db execer, l rating.Levels) error {
	_, err := db.ExecContext(ctx, `
INSERT INTO rating_ladder_state (id, fingerprint, levels, updated_at) VALUES (1, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET fingerprint = excluded.fingerprint, levels = excluded.levels,
  updated_at = excluded.updated_at`,
		l.Fingerprint(), l.Encode(), time.Now().UTC().Format(time.RFC3339))
	if err != nil {
		return fmt.Errorf("store rating_ladder_state: %w", err)
	}
	return nil
}

// startupReconcileRatingLadder is main's call: reconcile and log, never fatal. A failure
// costs only stale offline levels until the next start, which retries.
func (s *Server) startupReconcileRatingLadder(ctx context.Context) {
	res, err := s.reconcileRatingLadder(ctx)
	switch {
	case err != nil:
		log.Printf("[rating] ladder reconcile failed, retried next start: %v", err)
	case res.Baseline && res.Bumped > 0:
		log.Printf("[rating] ladder fingerprint recorded (first run): %d item(s) re-sequenced at change_seq %d", res.Bumped, res.Seq)
	case res.Baseline:
		log.Printf("[rating] ladder fingerprint recorded (first run)")
	case res.Changed:
		log.Printf("[rating] ladder changed: %d item(s) re-sequenced at change_seq %d", res.Bumped, res.Seq)
	}
}
