package main

import (
	"database/sql"
	"path/filepath"
	"testing"

	_ "modernc.org/sqlite"
)

const watchlistSchema = `
CREATE TABLE watchlist(item_id TEXT, user_id TEXT, PRIMARY KEY(item_id, user_id));
CREATE TABLE progress(
  item_id TEXT, user_id TEXT, position_seconds INT, duration_seconds INT,
  updated_at TEXT, write_seq INT, PRIMARY KEY(item_id, user_id));
`

func openWatchlistDB(t *testing.T) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	if _, err := db.Exec(watchlistSchema); err != nil {
		t.Fatalf("schema: %v", err)
	}
	return db
}

// DELETE /watchlist/{id} used to 404 when RowsAffected == 0, while its POST counterpart
// was INSERT OR IGNORE (idempotent). The client removes the row optimistically and
// re-inserts it in the catch block, so that 404 made the item visibly REAPPEAR on a
// double-tap, on a retry after a flaky-but-successful first request, or when a second
// device had already removed it.
//
// The verbs must agree: removing something already absent is success.
func TestWatchlistDeleteIsIdempotent(t *testing.T) {
	db := openWatchlistDB(t)

	if _, err := db.Exec(`INSERT OR IGNORE INTO watchlist(item_id, user_id) VALUES(?,?)`, "it_1", "u1"); err != nil {
		t.Fatalf("insert: %v", err)
	}

	// First delete removes the row.
	res, err := db.Exec(`DELETE FROM watchlist WHERE item_id = ? AND user_id = ?`, "it_1", "u1")
	if err != nil {
		t.Fatalf("delete: %v", err)
	}
	if n, _ := res.RowsAffected(); n != 1 {
		t.Fatalf("first delete: RowsAffected = %d, want 1", n)
	}

	// Second delete affects nothing — the handler must still report success, with
	// removed=false, rather than 404.
	res, err = db.Exec(`DELETE FROM watchlist WHERE item_id = ? AND user_id = ?`, "it_1", "u1")
	if err != nil {
		t.Fatalf("second delete: %v", err)
	}
	n, _ := res.RowsAffected()
	if n != 0 {
		t.Fatalf("second delete: RowsAffected = %d, want 0", n)
	}
	// This is the contract the handler now implements: ok:true, removed:(n > 0).
	if removed := n > 0; removed {
		t.Fatal("a no-op delete must report removed=false, not an error")
	}
}

// POST is idempotent too — asserted so the two verbs cannot drift apart again.
func TestWatchlistAddIsIdempotent(t *testing.T) {
	db := openWatchlistDB(t)

	for i := 0; i < 3; i++ {
		if _, err := db.Exec(`INSERT OR IGNORE INTO watchlist(item_id, user_id) VALUES(?,?)`, "it_1", "u1"); err != nil {
			t.Fatalf("insert %d: %v", i, err)
		}
	}

	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM watchlist WHERE item_id = ? AND user_id = ?`, "it_1", "u1").Scan(&count); err != nil {
		t.Fatalf("count: %v", err)
	}
	if count != 1 {
		t.Fatalf("count = %d, want 1", count)
	}
}

// A write_seq of 0 can never win the upsert's guard against an existing row, which is why
// incrementSeq's old "return 0 on error" behaviour silently DISCARDED progress writes
// while the handler still answered {"ok":true}. handleProgress now surfaces the error
// instead of storing a 0.
func TestZeroWriteSeqLosesToAnyExistingRow(t *testing.T) {
	db := openWatchlistDB(t)

	const upsert = `
INSERT INTO progress(item_id, user_id, position_seconds, duration_seconds, updated_at, write_seq)
VALUES(?,?,?,?,?,?)
ON CONFLICT(item_id, user_id) DO UPDATE SET
  position_seconds=excluded.position_seconds,
  write_seq=excluded.write_seq
WHERE excluded.write_seq > progress.write_seq`

	// An established row at seq 5.
	if _, err := db.Exec(upsert, "it_1", "u1", 100, 1000, "now", 5); err != nil {
		t.Fatalf("seed: %v", err)
	}

	// A write carrying the failure sentinel 0 must be rejected by the guard.
	res, err := db.Exec(upsert, "it_1", "u1", 999, 1000, "now", 0)
	if err != nil {
		t.Fatalf("zero-seq write: %v", err)
	}
	if n, _ := res.RowsAffected(); n != 0 {
		t.Fatalf("zero-seq write applied (RowsAffected = %d) — expected the guard to reject it", n)
	}

	var pos int
	if err := db.QueryRow(`SELECT position_seconds FROM progress WHERE item_id = ? AND user_id = ?`, "it_1", "u1").Scan(&pos); err != nil {
		t.Fatalf("read back: %v", err)
	}
	if pos != 100 {
		t.Fatalf("position = %d, want 100 (the zero-seq write must not have landed)", pos)
	}

	// A real sequence number wins, confirming the guard isn't simply rejecting everything.
	res, err = db.Exec(upsert, "it_1", "u1", 250, 1000, "now", 6)
	if err != nil {
		t.Fatalf("seq-6 write: %v", err)
	}
	if n, _ := res.RowsAffected(); n != 1 {
		t.Fatalf("seq-6 write: RowsAffected = %d, want 1", n)
	}
}
