package normalize

import (
	"database/sql"
	"encoding/hex"
	"path/filepath"
	"testing"

	"dsvideo/backend/internal/transcode"

	_ "modernc.org/sqlite"
)

// itemIDFromPath mirrors the production id derivation (main.go itemIDFromPath) so the
// test asserts re-keying lands on exactly the id a library rescan would derive.
func itemIDFromPath(path string) string {
	return "it_" + hex.EncodeToString([]byte(filepath.Clean(path)))
}

// newRekeyTestDB builds an in-memory DB with the minimal items + FK schema RekeyAndMigrate
// touches. Mirrors the composite PKs of the real schema (item_id first).
func newRekeyTestDB(t *testing.T) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	stmts := []string{
		`CREATE TABLE items (
			id TEXT PRIMARY KEY, path TEXT, video_codec TEXT, audio_codec TEXT,
			container TEXT, needs_transcode INTEGER, duration_seconds INTEGER,
			video_width INTEGER, video_height INTEGER, audio_channels INTEGER,
			change_seq INTEGER)`,
		`CREATE TABLE progress (item_id TEXT NOT NULL, user_id TEXT NOT NULL,
			position_seconds INTEGER, PRIMARY KEY (item_id, user_id))`,
		`CREATE TABLE watchlist (item_id TEXT NOT NULL, user_id TEXT NOT NULL,
			PRIMARY KEY (item_id, user_id))`,
		`CREATE TABLE downloads (item_id TEXT NOT NULL, user_id TEXT NOT NULL,
			PRIMARY KEY (item_id, user_id))`,
		`CREATE TABLE playlist_items (playlist_id TEXT NOT NULL, item_id TEXT NOT NULL,
			position INTEGER, PRIMARY KEY (playlist_id, item_id))`,
	}
	for _, s := range stmts {
		if _, err := db.Exec(s); err != nil {
			t.Fatalf("schema: %v", err)
		}
	}
	return db
}

func countRows(t *testing.T, db *sql.DB, query string, args ...any) int {
	t.Helper()
	var n int
	if err := db.QueryRow(query, args...).Scan(&n); err != nil {
		t.Fatalf("count (%s): %v", query, err)
	}
	return n
}

// TestRekeyAndMigrate_HappyPath is the core proof of the O'Brien fix: a different-path
// conversion (.mkv → .mp4) re-keys the items row to hex(.mp4) and drags its progress row
// along, leaving exactly one items row under the new id and zero under the old.
func TestRekeyAndMigrate_HappyPath(t *testing.T) {
	db := newRekeyTestDB(t)

	mkv := "/v/Movies/Film.mkv"
	mp4 := "/v/Movies/Film.mp4"
	oldID := itemIDFromPath(mkv)
	newID := itemIDFromPath(mp4)
	if oldID == newID {
		t.Fatal("precondition: old/new ids must differ")
	}

	if _, err := db.Exec(
		`INSERT INTO items (id, path, video_codec, container, needs_transcode, change_seq)
		 VALUES (?, ?, 'hevc', 'mkv', 1, 1)`, oldID, mkv); err != nil {
		t.Fatalf("seed item: %v", err)
	}
	if _, err := db.Exec(
		`INSERT INTO progress (item_id, user_id, position_seconds) VALUES (?, 'u1', 42)`,
		oldID); err != nil {
		t.Fatalf("seed progress: %v", err)
	}

	probe := &transcode.ProbeResult{
		Container: "mp4", VideoCodec: "h264", AudioCodec: "aac",
		NeedsTranscode: false, DurationSecs: 100, Width: 1920, Height: 1080, AudioChannels: 2,
	}
	if err := RekeyAndMigrate(db, oldID, newID, mp4, probe, 7); err != nil {
		t.Fatalf("RekeyAndMigrate: %v", err)
	}

	// Exactly one items row, carrying the new id + path + probe codecs + seq.
	if n := countRows(t, db, `SELECT COUNT(*) FROM items`); n != 1 {
		t.Fatalf("items row count = %d, want 1 (no duplicate)", n)
	}
	if n := countRows(t, db, `SELECT COUNT(*) FROM items WHERE id = ?`, oldID); n != 0 {
		t.Errorf("old id still present (%d rows)", n)
	}
	var (
		gotPath, gotVC string
		gotNT          int
		gotSeq         int64
	)
	if err := db.QueryRow(
		`SELECT path, video_codec, needs_transcode, change_seq FROM items WHERE id = ?`, newID,
	).Scan(&gotPath, &gotVC, &gotNT, &gotSeq); err != nil {
		t.Fatalf("read re-keyed item: %v", err)
	}
	if gotPath != mp4 || gotVC != "h264" || gotNT != 0 || gotSeq != 7 {
		t.Errorf("re-keyed item = path %q vc %q nt %d seq %d; want %q h264 0 7",
			gotPath, gotVC, gotNT, gotSeq, mp4)
	}

	// Progress row followed the item to the new id.
	if n := countRows(t, db, `SELECT COUNT(*) FROM progress WHERE item_id = ?`, oldID); n != 0 {
		t.Errorf("progress still on old id (%d rows)", n)
	}
	var pos int
	if err := db.QueryRow(
		`SELECT position_seconds FROM progress WHERE item_id = ? AND user_id = 'u1'`, newID,
	).Scan(&pos); err != nil {
		t.Fatalf("progress not migrated to new id: %v", err)
	}
	if pos != 42 {
		t.Errorf("migrated progress position = %d, want 42", pos)
	}
}

// TestRekeyAndMigrate_RescanBeatUs covers the conflict: a library rescan already created
// the hex(.mp4) items row before normalize re-keyed. The pre-existing newID row must be
// cleared so we end with exactly one row (the re-keyed one), not a PK violation.
func TestRekeyAndMigrate_RescanBeatUs(t *testing.T) {
	db := newRekeyTestDB(t)
	mkv, mp4 := "/v/Movies/Dup.mkv", "/v/Movies/Dup.mp4"
	oldID, newID := itemIDFromPath(mkv), itemIDFromPath(mp4)

	// Old (.mkv) row + a stale rescan-created (.mp4) row already keyed newID.
	if _, err := db.Exec(`INSERT INTO items (id, path, change_seq) VALUES (?, ?, 1), (?, ?, 2)`,
		oldID, mkv, newID, mp4); err != nil {
		t.Fatalf("seed two items: %v", err)
	}

	probe := &transcode.ProbeResult{Container: "mp4", VideoCodec: "h264", AudioCodec: "aac"}
	if err := RekeyAndMigrate(db, oldID, newID, mp4, probe, 9); err != nil {
		t.Fatalf("RekeyAndMigrate: %v", err)
	}
	if n := countRows(t, db, `SELECT COUNT(*) FROM items`); n != 1 {
		t.Fatalf("items row count = %d, want 1 after conflict resolution", n)
	}
	var vc string
	var seq int64
	if err := db.QueryRow(`SELECT video_codec, change_seq FROM items WHERE id = ?`, newID).
		Scan(&vc, &seq); err != nil {
		t.Fatalf("read winner: %v", err)
	}
	if vc != "h264" || seq != 9 {
		t.Errorf("winning row = vc %q seq %d, want h264 9 (re-keyed row, not the stale rescan row)", vc, seq)
	}
}

// TestRekeyAndMigrate_FKCollision covers an FK row that already exists under the new id
// (e.g. the user has progress on both .mkv and a rescan-created .mp4 item). UPDATE OR
// IGNORE must not PK-collide, and the stale (oldID, user) row must be pruned.
func TestRekeyAndMigrate_FKCollision(t *testing.T) {
	db := newRekeyTestDB(t)
	mkv, mp4 := "/v/Movies/Coll.mkv", "/v/Movies/Coll.mp4"
	oldID, newID := itemIDFromPath(mkv), itemIDFromPath(mp4)

	if _, err := db.Exec(`INSERT INTO items (id, path, change_seq) VALUES (?, ?, 1)`, oldID, mkv); err != nil {
		t.Fatalf("seed item: %v", err)
	}
	// Same user has progress under BOTH ids — collision on (newID, u1).
	if _, err := db.Exec(
		`INSERT INTO progress (item_id, user_id, position_seconds) VALUES (?, 'u1', 10), (?, 'u1', 20)`,
		oldID, newID); err != nil {
		t.Fatalf("seed colliding progress: %v", err)
	}

	probe := &transcode.ProbeResult{Container: "mp4", VideoCodec: "h264"}
	if err := RekeyAndMigrate(db, oldID, newID, mp4, probe, 3); err != nil {
		t.Fatalf("RekeyAndMigrate: %v", err)
	}
	// Exactly one progress row for (newID, u1); the stale old-id row is gone.
	if n := countRows(t, db, `SELECT COUNT(*) FROM progress`); n != 1 {
		t.Fatalf("progress row count = %d, want 1", n)
	}
	var pos int
	if err := db.QueryRow(`SELECT position_seconds FROM progress WHERE item_id = ? AND user_id = 'u1'`, newID).
		Scan(&pos); err != nil {
		t.Fatalf("read surviving progress: %v", err)
	}
	// UPDATE OR IGNORE kept the pre-existing newID row (pos 20); the old-id row (pos 10)
	// was pruned. Either retained value is acceptable; assert the old id is fully gone.
	if pos != 20 && pos != 10 {
		t.Errorf("unexpected surviving position %d", pos)
	}
	if n := countRows(t, db, `SELECT COUNT(*) FROM progress WHERE item_id = ?`, oldID); n != 0 {
		t.Errorf("stale old-id progress not pruned (%d rows)", n)
	}
}

// TestRekeyAndMigrate_RejectsSameID guards the contract: callers must route same-path
// (id-unchanged) conversions to the simple update, not here.
func TestRekeyAndMigrate_RejectsSameID(t *testing.T) {
	db := newRekeyTestDB(t)
	id := itemIDFromPath("/v/Movies/Same.mp4")
	if err := RekeyAndMigrate(db, id, id, "/v/Movies/Same.mp4",
		&transcode.ProbeResult{Container: "mp4"}, 1); err == nil {
		t.Error("expected error when newID == oldID")
	}
}
