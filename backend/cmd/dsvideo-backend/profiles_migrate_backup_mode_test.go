package main

import (
	"database/sql"
	"os"
	"path/filepath"
	"testing"
)

// The FR-232 pre-migration copy holds every account's watch history. VACUUM INTO creates it
// world-readable; it must be owner-only. Red if the Chmod in backupBeforeProfiles is removed.
func TestPreProfilesBackupIsOwnerOnly(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "dsvideo.db")
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer db.Close()
	if _, err := db.Exec(`CREATE TABLE progress (item_id TEXT, user_id TEXT); INSERT INTO progress VALUES ('a','u')`); err != nil {
		t.Fatalf("seed: %v", err)
	}
	backup, err := backupBeforeProfiles(db, dbPath)
	if err != nil {
		t.Fatalf("backupBeforeProfiles: %v", err)
	}
	fi, err := os.Stat(backup)
	if err != nil {
		t.Fatalf("stat backup: %v", err)
	}
	if mode := fi.Mode().Perm(); mode != 0o600 {
		t.Fatalf("pre-migration copy mode = %o, want 600 (it holds every account's history)", mode)
	}
}
