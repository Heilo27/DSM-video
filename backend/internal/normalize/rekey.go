package normalize

import (
	"context"
	"database/sql"
	"fmt"

	"dsvideo/backend/internal/sqltx"
	"dsvideo/backend/internal/transcode"
)

// fkItemTables are the tables whose item_id column is a loose (non-CASCADE) reference to
// items.id. When a normalize conversion changes a file's path — and therefore its derived
// item id (id = "it_"+hex(cleanPath)) — these rows must be re-pointed at the new id or
// they orphan. Each has a composite PRIMARY KEY whose first column is item_id, so a plain
// UPDATE could PK-collide with a pre-existing row for the new id; we migrate with
// UPDATE OR IGNORE then DELETE the stragglers (see RekeyAndMigrate).
//
// deleted_items is intentionally excluded: it is the delta-sync tombstone log recording
// ids that were *removed*, not a live reference that should follow the item.
var fkItemTables = []string{"progress", "watchlist", "downloads", "playlist_items"}

// RekeyAndMigrate re-keys an items row from oldID to newID, repoints its path + codec
// columns to the converted file, and migrates every loose item_id FK reference — all in a
// single transaction. It is the different-path arm of the auto-normalize DB update: when a
// conversion moves Movie.mkv → Movie.mp4 the item's derived id changes from hex(.mkv) to
// hex(.mp4), so leaving the id stable would make the next library rescan upsert a SECOND
// row keyed hex(.mp4) (duplicate item for one file). Re-keying to hex(.mp4) here means the
// rescan finds the row by that id and updates it in place — no duplicate.
//
// Conflict handling (rescan beats us to it): if a row with newID already exists in items
// (a prior rescan already created the hex(.mp4) row), it is DELETEd first, then the oldID
// row is updated to carry newID. This can never leave zero rows (the oldID row always
// exists — it is the one we just converted) nor two rows (any newID row is removed before
// the rename). FK rows migrate with UPDATE OR IGNORE so a pre-existing (newID, user) row
// doesn't violate the composite PK; any now-stale (oldID, …) leftovers are then DELETEd.
//
// On any error the whole transaction rolls back and the caller falls back to a path-only
// repoint (preserving the 404 fix even if re-keying fails).
//
// It does not touch progress_seq; the server's caller of RekeyAndMigrateTx does (see there).
func RekeyAndMigrate(db *sql.DB, oldID, newID, cleanPath string, probe *transcode.ProbeResult, seq int64) error {
	if db == nil {
		return fmt.Errorf("rekey: nil db")
	}
	if probe == nil {
		return fmt.Errorf("rekey: nil probe")
	}
	if newID == oldID {
		return fmt.Errorf("rekey: newID == oldID (%s) — caller should use the same-path update", oldID)
	}

	// sqltx: a refused COMMIT must not leave the connection holding the write lock (TASK-941).
	err := sqltx.Run(context.Background(), db, func(tx *sql.Tx) error {
		_, err := RekeyAndMigrateTx(tx, oldID, newID, cleanPath, probe, seq)
		return err
	})
	return err // RekeyAndMigrateTx's errors carry "rekey:"; sqltx.Run prefixes a commit failure
}

// RekeyAndMigrateTx is RekeyAndMigrate inside a transaction the caller owns (and commits).
//
// It exists so the caller can allocate the row's item_seq in the SAME transaction. SQLite
// admits one writer at a time, so a sequence allocated inside the writing transaction cannot
// be overtaken: no later sequence can be allocated, committed and advertised on /sync while
// this row is still uncommitted. Allocating outside (autocommit) and writing afterwards
// opened exactly that window, and a device whose cursor passed the later sequence never
// fetched this row (TASK-919).
//
// progressRows is how many progress rows the re-key changed: re-pointed at newID, or
// dropped as stale duplicates of a newID row. Devices learn about progress changes only from
// a progress_seq bump (they refetch /progress/all when it moves), so when progressRows > 0
// the caller must allocate a progress_seq in this same transaction and publish it after
// commit. Without that, every device kept the position under the old id, which no longer
// exists, until some unrelated progress write moved the counter (TASK-941).
func RekeyAndMigrateTx(tx *sql.Tx, oldID, newID, cleanPath string, probe *transcode.ProbeResult, seq int64) (progressRows int64, err error) {
	if tx == nil {
		return 0, fmt.Errorf("rekey: nil tx")
	}
	if probe == nil {
		return 0, fmt.Errorf("rekey: nil probe")
	}
	if newID == oldID {
		return 0, fmt.Errorf("rekey: newID == oldID (%s) — caller should use the same-path update", oldID)
	}

	// 1. Clear any items row already sitting on the destination id (a rescan that beat us).
	//    After this DELETE the UPDATE below cannot PK-collide.
	if _, err := tx.Exec(`DELETE FROM items WHERE id = ?`, newID); err != nil {
		return 0, fmt.Errorf("rekey: clear conflicting newID row: %w", err)
	}

	// 2. Re-key the converted row: stamp the new id + path + probe codec columns + seq.
	res, err := tx.Exec(
		`UPDATE items SET id = ?, path = ?, video_codec = ?, audio_codec = ?, container = ?,
		 needs_transcode = ?, duration_seconds = ?, video_width = ?, video_height = ?,
		 audio_channels = ?, change_seq = ? WHERE id = ?`,
		newID, cleanPath, probe.VideoCodec, probe.AudioCodec, probe.Container,
		probe.NeedsTranscode, int(probe.DurationSecs), probe.Width, probe.Height,
		probe.AudioChannels, seq, oldID,
	)
	if err != nil {
		return 0, fmt.Errorf("rekey: update items: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return 0, fmt.Errorf("rekey: no items row with id %s", oldID)
	}

	// 3. Migrate loose FK references. UPDATE OR IGNORE skips rows that would collide with a
	//    pre-existing (newID, …) PK; the follow-up DELETE drops the now-stale (oldID, …)
	//    rows so nothing is orphaned and no duplicate FK rows linger.
	for _, table := range fkItemTables {
		moved, err := tx.Exec(
			fmt.Sprintf(`UPDATE OR IGNORE %s SET item_id = ? WHERE item_id = ?`, table),
			newID, oldID,
		)
		if err != nil {
			return 0, fmt.Errorf("rekey: migrate %s: %w", table, err)
		}
		pruned, err := tx.Exec(
			fmt.Sprintf(`DELETE FROM %s WHERE item_id = ?`, table), oldID,
		)
		if err != nil {
			return 0, fmt.Errorf("rekey: prune stale %s: %w", table, err)
		}
		if table == "progress" {
			m, _ := moved.RowsAffected()
			p, _ := pruned.RowsAffected()
			progressRows = m + p
		}
	}
	return progressRows, nil
}
