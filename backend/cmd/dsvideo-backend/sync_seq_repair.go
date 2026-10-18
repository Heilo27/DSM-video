package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"dsvideo/backend/internal/sqltx"
)

// repairRunawayItemSeq is the ONE home of the startup repair for a runaway item_seq
// (TASK-987). main() calls it at boot and the test suite calls it directly, so a test of the
// repair is a test of the code that runs on the NAS and not of a copy that can drift.
//
// Background. A scan bug (fixed) previously allocated a sequence number for every file on
// every 5-minute pass whether or not the row changed, driving item_seq to 110,235,720
// against a 5,108-item library. Clients compare their cursor to this value, so an inflated
// counter makes every sync cycle look like the entire library changed: the NAS served
// ~36,000 paged requests and 17.5TB of reads before it was caught.
//
// Detection. The buggy scan wrote its inflated counter into items.change_seq as well, so
// item_seq and MAX(change_seq) ran away together and comparing them finds nothing. The
// usable signal is item_seq measured against the ITEM COUNT: a healthy library's sequence
// numbers stay within a small multiple of N. The live failure sat at ~21,500x; heavy but
// legitimate churn is well under 1,000x.
//
// Repair. Rebase the counter and every row onto a compact range in one transaction.
// change_seq is renumbered by current order, so relative ordering (all that delta sync
// depends on) is preserved exactly. Clients whose stored cursor is now above item_seq will
// re-sync once, then stay quiet.
//
// It returns repaired=false with a nil error when the library is healthy (nothing touched).
// seqBefore and itemCount describe what it found; on repaired=true the counter is now
// itemCount.
func repairRunawayItemSeq(ctx context.Context, db *sql.DB) (repaired bool, seqBefore, itemCount int64, err error) {
	if err := db.QueryRowContext(ctx, `SELECT value FROM sync_state WHERE key = 'item_seq'`).Scan(&seqBefore); err != nil && !errors.Is(err, sql.ErrNoRows) {
		return false, 0, 0, fmt.Errorf("read item_seq: %w", err)
	}
	if err := db.QueryRowContext(ctx, `SELECT COUNT(*) FROM items`).Scan(&itemCount); err != nil {
		return false, seqBefore, 0, fmt.Errorf("count items: %w", err)
	}
	if !(itemCount > 0 && seqBefore > 1000*itemCount && seqBefore > 100000) {
		return false, seqBefore, itemCount, nil
	}

	// sqltx, not db.Begin: a refused COMMIT must not return this connection to the pool
	// still holding the write lock (TASK-941).
	err = sqltx.Run(ctx, db, func(tx *sql.Tx) error {
		if _, err := tx.ExecContext(ctx, `
			WITH renum AS (
				SELECT id, ROW_NUMBER() OVER (ORDER BY change_seq ASC, rowid ASC) AS n FROM items
			)
			UPDATE items SET change_seq = (SELECT n FROM renum WHERE renum.id = items.id)`); err != nil {
			return fmt.Errorf("renumber items: %w", err)
		}
		// deleted_items was written from the SAME inflated counter, so it has to be rebased
		// in the same transaction. Leaving it alone strands every tombstone permanently
		// above item_seq: /sync/deleted returns the whole history on every request, and
		// any tombstone naming a since-rescanned item makes the client delete a row that
		// exists. Clamp them to the new ceiling so they stay ordered and fall below all
		// future deletions.
		if _, err := tx.ExecContext(ctx,
			`UPDATE deleted_items SET change_seq = ? WHERE change_seq > ?`, itemCount, itemCount); err != nil {
			return fmt.Errorf("rebase tombstones: %w", err)
		}
		// Drop tombstones for items that exist again: a rescan re-added them, so the
		// deletion is no longer true and must never be replayed.
		if _, err := tx.ExecContext(ctx,
			`DELETE FROM deleted_items WHERE item_id IN (SELECT id FROM items)`); err != nil {
			return fmt.Errorf("drop stale tombstones: %w", err)
		}
		if _, err := tx.ExecContext(ctx,
			`UPDATE sync_state SET value = ? WHERE key = 'item_seq'`, itemCount); err != nil {
			return fmt.Errorf("reset item_seq: %w", err)
		}
		return nil
	})
	if err != nil {
		return false, seqBefore, itemCount, err
	}
	return true, seqBefore, itemCount, nil
}
