package main

import (
	"database/sql"
	"path/filepath"
	"testing"

	_ "modernc.org/sqlite"
)

// schema mirrors the columns the scan upsert touches. Kept minimal on purpose —
// these tests are about change_seq accounting, not the full item shape.
const testSchema = `
CREATE TABLE items(
  id TEXT PRIMARY KEY, library_id TEXT, type TEXT, title TEXT, year INT,
  path TEXT, duration_seconds INT, added_at TEXT, updated_at TEXT,
  video_codec TEXT, audio_codec TEXT, container TEXT, needs_transcode BOOL,
  change_seq INT, show_folder_id TEXT, video_width INT, video_height INT,
  audio_channels INT, tmdb_id INT);
CREATE TABLE sync_state(key TEXT PRIMARY KEY, value INT);
INSERT INTO sync_state VALUES('item_seq', 0);
`

// upsertSQL is the scan's item upsert, including the WHERE guard that makes an
// unchanged row a no-op. Kept in sync with flushBatch in main.go.
const upsertSQL = `
INSERT INTO items(id, library_id, type, title, year, path, duration_seconds, added_at, updated_at, change_seq)
VALUES(?,?,?,?,?,?,?,?,?,?)
ON CONFLICT(id) DO UPDATE SET
  library_id=excluded.library_id, type=excluded.type, path=excluded.path,
  added_at=excluded.added_at, updated_at=excluded.updated_at,
  duration_seconds=COALESCE(excluded.duration_seconds, items.duration_seconds),
  title=CASE WHEN items.tmdb_id IS NULL THEN excluded.title ELSE items.title END,
  year=CASE WHEN items.tmdb_id IS NULL THEN excluded.year ELSE items.year END,
  change_seq=excluded.change_seq
WHERE items.library_id IS NOT excluded.library_id
   OR items.type IS NOT excluded.type
   OR items.path IS NOT excluded.path
   OR items.added_at IS NOT excluded.added_at
   OR items.duration_seconds IS NOT COALESCE(excluded.duration_seconds, items.duration_seconds)
   OR items.title IS NOT (CASE WHEN items.tmdb_id IS NULL THEN excluded.title ELSE items.title END)
   OR items.year IS NOT (CASE WHEN items.tmdb_id IS NULL THEN excluded.year ELSE items.year END)`

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
	res, err := db.Exec(upsertSQL,
		id, "lib_movies", "video", title, 1995, path, nil, "2026-01-01", "now", seq)
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
func TestRunawayItemSeqRepair(t *testing.T) {
	repair := func(db *sql.DB) bool {
		var seq, count int64
		db.QueryRow(`SELECT value FROM sync_state WHERE key='item_seq'`).Scan(&seq)
		db.QueryRow(`SELECT COUNT(*) FROM items`).Scan(&count)
		if !(count > 0 && seq > 1000*count && seq > 100000) {
			return false
		}
		tx, err := db.Begin()
		if err != nil {
			return false
		}
		if _, err := tx.Exec(`
			WITH renum AS (SELECT id, ROW_NUMBER() OVER (ORDER BY change_seq ASC, rowid ASC) AS n FROM items)
			UPDATE items SET change_seq = (SELECT n FROM renum WHERE renum.id = items.id)`); err != nil {
			tx.Rollback()
			return false
		}
		if _, err := tx.Exec(`UPDATE sync_state SET value = ? WHERE key='item_seq'`, count); err != nil {
			tx.Rollback()
			return false
		}
		return tx.Commit() == nil
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

		if !repair(db) {
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

	t.Run("healthy library untouched", func(t *testing.T) {
		db := newTestDB(t)
		db.Exec(`UPDATE sync_state SET value=5200 WHERE key='item_seq'`)
		for i := 1; i <= 100; i++ {
			db.Exec(`INSERT INTO items(id, change_seq) VALUES(?,?)`, string(rune('a'+i%26))+string(rune('0'+i/26)), i)
		}
		if repair(db) {
			t.Error("repair fired on a healthy library — would force a needless full resync")
		}
	})
}
