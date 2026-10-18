package main

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"

	_ "modernc.org/sqlite"
)

// The schema must carry EVERY column itemUpsertSQL touches — that is the point.
//
// This file used to define its own cut-down copy of the upsert (10 of 21 columns, 7 of 22
// WHERE clauses) alongside a matching cut-down schema, with a comment claiming it was
// "kept in sync with flushBatch". It was not, and the drift was invisible: the copy was
// missing every codec and probe column, so the test guarding the runaway-sequence outage
// could not see the half of the statement most likely to cause it.
//
// Both now come from production. Add a column to itemUpsertSQL without adding it here and
// these tests fail immediately with "no such column" — which is the alarm that was missing.
const testSchema = `
CREATE TABLE items(
  id TEXT PRIMARY KEY, library_id TEXT, type TEXT, title TEXT, year INT,
  path TEXT, duration_seconds INT, added_at TEXT, updated_at TEXT,
  video_codec TEXT, video_codec_tag TEXT, audio_codec TEXT, container TEXT,
  needs_transcode BOOL, change_seq INT, show_folder_id TEXT,
  video_width INT, video_height INT, audio_channels INT,
  size_bytes INT, probed_at TEXT, tmdb_id INT);
CREATE TABLE sync_state(key TEXT PRIMARY KEY, value INT);
CREATE TABLE deleted_items(item_id TEXT NOT NULL, change_seq INTEGER NOT NULL, deleted_at TEXT NOT NULL);
INSERT INTO sync_state VALUES('item_seq', 0);
`

// The upsert itself is itemUpsertSQL from main.go — not a copy. See testSchema above.

func newTestDB(t *testing.T) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	if _, err := db.Exec(testSchema); err != nil {
		t.Fatalf("schema: %v", err)
	}
	return db
}

// scanOnce simulates one scan pass over a single file, mirroring flushBatch:
// allocate a seq, attempt the upsert, roll the seq back when nothing changed.
func scanOnce(t *testing.T, db *sql.DB, id, path, title string) {
	t.Helper()
	var seq int64
	if err := db.QueryRow(
		`UPDATE sync_state SET value = value + 1 WHERE key = 'item_seq' RETURNING value`,
	).Scan(&seq); err != nil {
		t.Fatalf("alloc seq: %v", err)
	}
	// Parameter order follows itemUpsertSQL exactly; a reordering there breaks here loudly
	// rather than silently writing the wrong column.
	res, err := db.Exec(itemUpsertSQL,
		id, "lib_movies", "video", title, 1995, path, nil, "2026-01-01", "now",
		nil, nil, nil, nil, nil, // video_codec, video_codec_tag, audio_codec, container, needs_transcode
		seq,
		nil, nil, nil, nil, nil, nil) // show_folder_id, video_width, video_height, audio_channels, size_bytes, probed_at
	if err != nil {
		t.Fatalf("upsert: %v", err)
	}
	if n, aErr := res.RowsAffected(); aErr == nil && n == 0 {
		if _, err := db.Exec(
			`UPDATE sync_state SET value = value - 1 WHERE key = 'item_seq' AND value = ?`, seq); err != nil {
			t.Fatalf("rollback seq: %v", err)
		}
	}
}

func itemSeq(t *testing.T, db *sql.DB) int64 {
	t.Helper()
	var v int64
	if err := db.QueryRow(`SELECT value FROM sync_state WHERE key='item_seq'`).Scan(&v); err != nil {
		t.Fatalf("read item_seq: %v", err)
	}
	return v
}

func changeSeq(t *testing.T, db *sql.DB, id string) int64 {
	t.Helper()
	var v int64
	if err := db.QueryRow(`SELECT change_seq FROM items WHERE id=?`, id).Scan(&v); err != nil {
		t.Fatalf("read change_seq: %v", err)
	}
	return v
}

// This is the regression guard for the outage: repeated scans of an UNCHANGED
// library must not advance item_seq or rewrite change_seq. When this broke, the
// live NAS reached item_seq=110,235,720 on 5,108 items and every client
// re-downloaded the whole library every 5 minutes (17.5TB of reads).
func TestScanOfUnchangedLibraryDoesNotAdvanceSeq(t *testing.T) {
	db := newTestDB(t)

	scanOnce(t, db, "a", "/m/heat.mkv", "Heat") // initial insert
	afterInsert := itemSeq(t, db)
	seqAfterInsert := changeSeq(t, db, "a")
	if afterInsert != 1 {
		t.Fatalf("first scan should allocate seq 1, got %d", afterInsert)
	}

	for i := 0; i < 25; i++ {
		scanOnce(t, db, "a", "/m/heat.mkv", "Heat")
	}

	if got := itemSeq(t, db); got != afterInsert {
		t.Errorf("item_seq advanced across 25 unchanged scans: %d -> %d (this is the outage bug)", afterInsert, got)
	}
	if got := changeSeq(t, db, "a"); got != seqAfterInsert {
		t.Errorf("change_seq rewritten on unchanged scan: %d -> %d (clients would re-sync)", seqAfterInsert, got)
	}
}

// A genuine change must still allocate a sequence and bump change_seq, otherwise
// delta sync would silently stop delivering updates.
func TestScanOfChangedRowAdvancesSeq(t *testing.T) {
	db := newTestDB(t)
	scanOnce(t, db, "a", "/m/heat.mkv", "Heat")
	before := itemSeq(t, db)

	scanOnce(t, db, "a", "/m/heat-remux.mkv", "Heat") // path changed

	after := itemSeq(t, db)
	if after <= before {
		t.Errorf("item_seq did not advance on a real change: %d -> %d", before, after)
	}
	if changeSeq(t, db, "a") != after {
		t.Errorf("change_seq should equal the newly allocated seq %d, got %d", after, changeSeq(t, db, "a"))
	}
}

// The startup repair must rebase a runaway counter while preserving relative
// ordering, and must leave a healthy library completely alone.
//
// TASK-987: this calls repairRunawayItemSeq, the same function main() runs at boot. It used
// to carry its own copy of the repair, which had already drifted (no tombstone handling).
func TestRunawayItemSeqRepair(t *testing.T) {
	repair := func(t *testing.T, db *sql.DB) bool {
		t.Helper()
		repaired, _, _, err := repairRunawayItemSeq(context.Background(), db)
		if err != nil {
			t.Fatalf("repairRunawayItemSeq: %v", err)
		}
		return repaired
	}

	t.Run("runaway is rebased and ordering preserved", func(t *testing.T) {
		db := newTestDB(t)
		// Reproduce the live shape: counter at 110,235,720 with change_seq clustered
		// just below it, exactly as the NAS was found.
		db.Exec(`UPDATE sync_state SET value=110235720 WHERE key='item_seq'`)
		for i := 1; i <= 200; i++ {
			db.Exec(`INSERT INTO items(id, change_seq) VALUES(?,?)`, string(rune('a'+i%26))+string(rune('0'+i/26)), 110230607+i)
		}
		var before []string
		rows, _ := db.Query(`SELECT id FROM items ORDER BY change_seq ASC, rowid ASC`)
		for rows.Next() {
			var id string
			rows.Scan(&id)
			before = append(before, id)
		}
		rows.Close()

		if !repair(t, db) {
			t.Fatal("repair did not fire on a clearly runaway counter")
		}

		var seq, maxCS, count int64
		db.QueryRow(`SELECT value FROM sync_state WHERE key='item_seq'`).Scan(&seq)
		db.QueryRow(`SELECT COALESCE(MAX(change_seq),0), COUNT(*) FROM items`).Scan(&maxCS, &count)
		if seq != count {
			t.Errorf("item_seq should rebase to item count %d, got %d", count, seq)
		}
		if maxCS > seq {
			t.Errorf("a row carries change_seq %d above item_seq %d — delta sync would skip it", maxCS, seq)
		}
		var after []string
		rows, _ = db.Query(`SELECT id FROM items ORDER BY change_seq ASC, rowid ASC`)
		for rows.Next() {
			var id string
			rows.Scan(&id)
			after = append(after, id)
		}
		rows.Close()
		for i := range before {
			if before[i] != after[i] {
				t.Fatalf("repair reordered items at %d: %q -> %q", i, before[i], after[i])
			}
		}
	})

	// deleted_items was written from the same inflated counter: left alone, every tombstone
	// sits above item_seq forever, and one naming a since-rescanned item deletes a live row
	// on the client.
	t.Run("tombstones are rebased and stale ones dropped", func(t *testing.T) {
		db := newTestDB(t)
		db.Exec(`UPDATE sync_state SET value=110235720 WHERE key='item_seq'`)
		for i := 1; i <= 200; i++ {
			db.Exec(`INSERT INTO items(id, change_seq) VALUES(?,?)`, string(rune('a'+i%26))+string(rune('0'+i/26)), 110230607+i)
		}
		for _, d := range []struct {
			id  string
			seq int64
		}{
			{"gone1", 110235000}, {"gone2", 110235500}, {"old", 5},
			{"b0", 110235600}, // b0 exists again: a rescan re-added it
		} {
			if _, err := db.Exec(`INSERT INTO deleted_items(item_id, change_seq, deleted_at) VALUES(?,?,'2026-01-01T00:00:00Z')`, d.id, d.seq); err != nil {
				t.Fatal(err)
			}
		}

		if !repair(t, db) {
			t.Fatal("repair did not fire")
		}

		seqOf := func(id string) (int64, bool) {
			var s int64
			err := db.QueryRow(`SELECT change_seq FROM deleted_items WHERE item_id = ?`, id).Scan(&s)
			return s, err == nil
		}
		for _, id := range []string{"gone1", "gone2"} {
			if s, ok := seqOf(id); !ok || s != 200 {
				t.Errorf("tombstone %s: seq=%d present=%v, want clamped to the item count 200", id, s, ok)
			}
		}
		if s, ok := seqOf("old"); !ok || s != 5 {
			t.Errorf("tombstone below the ceiling must be untouched: seq=%d present=%v, want 5", s, ok)
		}
		if _, ok := seqOf("b0"); ok {
			t.Error("a tombstone for an item that exists again must be dropped, or the client deletes a live row")
		}
		var above int
		db.QueryRow(`SELECT COUNT(*) FROM deleted_items WHERE change_seq > (SELECT value FROM sync_state WHERE key='item_seq')`).Scan(&above)
		if above != 0 {
			t.Errorf("%d tombstones still sit above item_seq", above)
		}
	})

	// All or nothing: a failure part-way leaves the library exactly as it was found.
	t.Run("failed repair rolls back and reports the error", func(t *testing.T) {
		db := newTestDB(t)
		db.Exec(`UPDATE sync_state SET value=110235720 WHERE key='item_seq'`)
		for i := 1; i <= 200; i++ {
			db.Exec(`INSERT INTO items(id, change_seq) VALUES(?,?)`, string(rune('a'+i%26))+string(rune('0'+i/26)), 110230607+i)
		}
		if _, err := db.Exec(`DROP TABLE deleted_items`); err != nil {
			t.Fatal(err)
		}
		repaired, _, _, err := repairRunawayItemSeq(context.Background(), db)
		if err == nil || repaired {
			t.Fatalf("repaired=%v err=%v, want an error and no repair", repaired, err)
		}
		var seq, minCS int64
		db.QueryRow(`SELECT value FROM sync_state WHERE key='item_seq'`).Scan(&seq)
		db.QueryRow(`SELECT MIN(change_seq) FROM items`).Scan(&minCS)
		if seq != 110235720 || minCS < 110230608 {
			t.Errorf("a failed repair left changes behind: item_seq=%d min change_seq=%d", seq, minCS)
		}
	})

	t.Run("healthy library untouched", func(t *testing.T) {
		db := newTestDB(t)
		db.Exec(`UPDATE sync_state SET value=5200 WHERE key='item_seq'`)
		for i := 1; i <= 100; i++ {
			db.Exec(`INSERT INTO items(id, change_seq) VALUES(?,?)`, string(rune('a'+i%26))+string(rune('0'+i/26)), i)
		}
		if repair(t, db) {
			t.Error("repair fired on a healthy library — would force a needless full resync")
		}
	})
}
