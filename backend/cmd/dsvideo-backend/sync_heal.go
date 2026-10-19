package main

// FRD-002 FR-246: devices left stale by the FR-245 page-boundary skip are healed once.
//
// Background. Before FR-245 the /sync/items cursor landed on a look-ahead row that was never
// sent, so a device paging through the feed lost one row at every page boundary (27 of 5,432
// rows on a real library; 17 rating levels diverged, all upward re-rates kept at a lower
// level). The fix stops new losses. It cannot repair a device that already lost rows: that
// device's cursor equals the server's item_seq, so its next sync asks for "change_seq >
// item_seq" and is told there is nothing to fetch. The dropped rows are still in the server's
// table, just stamped with change_seq values below every such cursor.
//
// Mechanism. The first start after the upgrade gives every item a fresh change_seq above the
// current item_seq, then advances item_seq to the highest value used. Every device, however
// stale, holds a cursor at or below the old item_seq, so its next sync sees item_seq ahead of
// its cursor and receives the whole library once. That needs no app update and no action
// from the user, and works for any released client because it relies only on the contract
// they already follow: fetch what is newer than the cursor.
//
// Why a re-stamp and not a sync epoch. The shipped clients have no epoch concept. The only
// "reset" they honour is a cursor AHEAD of the server's, which would need item_seq to go
// backwards, and publishSeqMax and the cached just-added rails assume it never does.
//
// Why distinct values and not one shared value. Rows sharing a change_seq page by rowid via
// nextAfterRowid. Distinct values need nothing but nextSeq, so a client that predates
// afterRowid still walks the feed to its end. The cost is item_seq jumping by the item count.
//
// Safety.
//   - Only items.change_seq and the item_seq counter change. Progress, watchlist, profiles,
//     deleted_items and every other item column are untouched.
//   - Rows are stamped in batches, one short transaction each, so the write lock is never
//     held for the whole library (the NAS is slow, and the playback and scan paths wait on
//     it). Memory is one batch of rowids. Rows are stamped in rowid order; the previous
//     relative order of change_seq is not preserved, which no client depends on because every
//     device re-fetches the lot.
//   - The new item_seq is committed in the SAME transaction that records the marker, after
//     the last batch. A crash or error before that leaves the counter and marker untouched:
//     the next start redoes the whole pass from the same base (idempotent, every row is
//     rewritten). Rows stamped above the unadvanced counter in the meantime are harmless: a
//     device that fetches them early re-fetches them once the counter catches up.
//   - It runs at startup before the HTTP server and the scanner, so no writer interleaves.
//   - A database with no items has nothing to heal and no stale device; the marker is
//     recorded so later items are never re-stamped by a later start.
//   - Once the marker row exists the pass never runs again. A restored older database
//     without the marker heals again, which is correct.

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"time"

	"dsvideo/backend/internal/sqltx"
)

// syncHealPageSkip names the heal for the FR-245 page-boundary skip. A future heal adds its
// own name; it does not edit this one.
const syncHealPageSkip = "fr245-page-boundary-skip"

// syncHealBatch is the number of rows stamped per transaction.
const syncHealBatch = 500

// syncHealResult reports what a heal pass did, for the log line and tests.
type syncHealResult struct {
	Ran     bool  // the pass re-stamped items (false: already applied, or nothing to heal)
	Rows    int64 // items re-stamped
	Batches int   // transactions used for the stamping
	FromSeq int64 // item_seq before
	ToSeq   int64 // item_seq after (equals FromSeq when not Ran)
}

// healStaleItemCursors runs the named heal once. See the file comment.
func healStaleItemCursors(ctx context.Context, db *sql.DB, name string, batch int) (syncHealResult, error) {
	var res syncHealResult
	if batch <= 0 {
		batch = syncHealBatch
	}
	if _, err := db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS sync_heals (
  name       TEXT PRIMARY KEY,
  applied_at TEXT NOT NULL,
  rows       INTEGER NOT NULL,
  from_seq   INTEGER NOT NULL,
  to_seq     INTEGER NOT NULL
)`); err != nil {
		return res, fmt.Errorf("create sync_heals: %w", err)
	}
	var applied int
	if err := db.QueryRowContext(ctx, `SELECT COUNT(*) FROM sync_heals WHERE name = ?`, name).Scan(&applied); err != nil {
		return res, fmt.Errorf("read sync_heals: %w", err)
	}
	if applied > 0 {
		return res, nil
	}

	var base, items int64
	if err := db.QueryRowContext(ctx, `SELECT value FROM sync_state WHERE key = 'item_seq'`).Scan(&base); err != nil {
		return res, fmt.Errorf("read item_seq: %w", err)
	}
	if err := db.QueryRowContext(ctx, `SELECT COUNT(*) FROM items`).Scan(&items); err != nil {
		return res, fmt.Errorf("count items: %w", err)
	}
	res.FromSeq, res.ToSeq = base, base
	if items == 0 {
		return res, recordSyncHeal(ctx, db, name, 0, base, base)
	}

	// Stamp base+1, base+2, ... in rowid order, one short transaction per batch.
	next := base
	lastRowid := int64(-1)
	for {
		if err := ctx.Err(); err != nil {
			return res, err
		}
		var stamped int64
		err := sqltx.Run(ctx, db, func(tx *sql.Tx) error {
			rowids, err := nextRowids(ctx, tx, lastRowid, batch)
			if err != nil {
				return err
			}
			stmt, err := tx.PrepareContext(ctx, `UPDATE items SET change_seq = ? WHERE rowid = ?`)
			if err != nil {
				return err
			}
			defer stmt.Close()
			for _, rid := range rowids {
				if _, err := stmt.ExecContext(ctx, next+1+stamped, rid); err != nil {
					return fmt.Errorf("stamp rowid %d: %w", rid, err)
				}
				stamped++
				lastRowid = rid
			}
			return nil
		})
		if err != nil {
			return res, fmt.Errorf("re-stamp batch %d: %w", res.Batches+1, err)
		}
		if stamped == 0 {
			break
		}
		next += stamped
		res.Rows += stamped
		res.Batches++
	}

	// Commit the counter and the marker together, last. The value guard refuses to move a
	// counter somebody else advanced.
	err := sqltx.Run(ctx, db, func(tx *sql.Tx) error {
		r, err := tx.ExecContext(ctx,
			`UPDATE sync_state SET value = ? WHERE key = 'item_seq' AND value = ?`, next, base)
		if err != nil {
			return fmt.Errorf("advance item_seq: %w", err)
		}
		if n, _ := r.RowsAffected(); n != 1 {
			return errors.New("item_seq changed during the heal; retried next start")
		}
		return recordSyncHeal(ctx, tx, name, res.Rows, base, next)
	})
	if err != nil {
		return res, err
	}
	res.Ran, res.ToSeq = true, next
	return res, nil
}

// nextRowids returns up to n item rowids greater than after, ascending.
func nextRowids(ctx context.Context, tx *sql.Tx, after int64, n int) ([]int64, error) {
	rows, err := tx.QueryContext(ctx, `SELECT rowid FROM items WHERE rowid > ? ORDER BY rowid LIMIT ?`, after, n)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []int64
	for rows.Next() {
		var rid int64
		if err := rows.Scan(&rid); err != nil {
			return nil, err
		}
		out = append(out, rid)
	}
	return out, rows.Err()
}

func recordSyncHeal(ctx context.Context, db execer, name string, rows, from, to int64) error {
	if _, err := db.ExecContext(ctx,
		`INSERT INTO sync_heals(name, applied_at, rows, from_seq, to_seq) VALUES (?, ?, ?, ?, ?)`,
		name, time.Now().UTC().Format(time.RFC3339), rows, from, to); err != nil {
		return fmt.Errorf("record sync heal: %w", err)
	}
	return nil
}

// startupHealStaleItemCursors is main's call: heal, publish, log, never fatal. A failure
// leaves stale devices as they were until the next start, which retries.
func (s *Server) startupHealStaleItemCursors(ctx context.Context) {
	started := time.Now()
	res, err := healStaleItemCursors(ctx, s.db, syncHealPageSkip, syncHealBatch)
	if err != nil {
		log.Printf("[sync] heal %s failed, retried next start: %v", syncHealPageSkip, err)
		return
	}
	if res.Ran {
		s.publishItemSeq(res.ToSeq)
		log.Printf("[sync] heal %s: %d item(s) re-stamped in %d batch(es), item_seq %d -> %d, %s",
			syncHealPageSkip, res.Rows, res.Batches, res.FromSeq, res.ToSeq, time.Since(started).Round(time.Millisecond))
	}
}
