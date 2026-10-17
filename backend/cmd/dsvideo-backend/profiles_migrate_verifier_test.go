package main

// FRD-002 FR-232 (OC-2107): the migration's own copy verifier. The fixture makes the copy
// produce the WRONG number of rows for one account, so the per-account row-count compare in
// migrateProfilesTx is the only thing standing between a corrupted copy and a commit (the
// EXCEPT value check passes: every old row IS present, just twice). Expected values are literals.
//
// Also the shared helpers for the AC-002-23 natural-failure tests, which must run as root and
// under -short instead of skipping (TASK-938).

import (
	"bytes"
	"database/sql"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

// naturalBackupFailure says how the copy was made impossible and what the error must name.
type naturalBackupFailure struct {
	how       string
	wantInErr []string
}

// forceNaturalBackupFailure makes the real backupBeforeProfiles fail without replacing a seam.
// First choice: a 0555 database folder (only if a probe write really fails). Fallback, used as
// root or on a filesystem that ignores directory modes: occupy every pre-migration copy name a
// run starting within `span` could choose, so the backup step refuses to overwrite. The name
// pattern below is the fixture's knowledge of FR-232's copy name, not a recomputed expectation.
func forceNaturalBackupFailure(t *testing.T, dbPath string, span time.Duration) naturalBackupFailure {
	t.Helper()
	dir := filepath.Dir(dbPath)
	if err := os.Chmod(dir, 0o555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0o755) })
	probe := filepath.Join(dir, "probe")
	f, err := os.Create(probe)
	if err != nil {
		return naturalBackupFailure{how: "read-only database folder (0555)", wantInErr: []string{"not writable", dir}}
	}
	f.Close()
	_ = os.Remove(probe)
	if err := os.Chmod(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	occupyBackupNames(t, dbPath, span)
	return naturalBackupFailure{
		how:       "0555 folder still writable (root or permissive FS); every copy name occupied instead",
		wantInErr: []string{"already exists; refusing to overwrite"},
	}
}

func occupyBackupNames(t *testing.T, dbPath string, span time.Duration) {
	t.Helper()
	start := time.Now().UTC().Add(-2 * time.Second)
	for d := time.Duration(0); d <= span; d += time.Second {
		name := dbPath + ".pre-profiles-" + start.Add(d).Format("20060102T150405Z") + ".db"
		if err := os.WriteFile(name, []byte("occupied by the test"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func buildBackendBinary(t *testing.T) string {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "dsvideo-backend-qa")
	if out, err := exec.Command("go", "build", "-o", bin, ".").CombinedOutput(); err != nil {
		t.Fatalf("go build: %v\n%s", err, out)
	}
	return bin
}

// runBackendUntilExit starts the real server on dbPath and returns its exit code and log. A
// server still running after timeoutSec is a failure: startup was supposed to be refused.
func runBackendUntilExit(t *testing.T, bin, dbPath string, timeoutSec int) (int, string) {
	t.Helper()
	cmd := exec.Command(bin)
	cmd.Env = append(os.Environ(),
		"DSVIDEO_DB_PATH="+dbPath,
		"DSVIDEO_JWT_SECRET=qa-startup-secret-qa-startup-secret",
		"DSVIDEO_PORT=0",
	)
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		if err == nil {
			return 0, out.String()
		}
		var ee *exec.ExitError
		if !errors.As(err, &ee) {
			t.Fatalf("server did not run: %v\n%s", err, out.String())
		}
		return ee.ExitCode(), out.String()
	case <-after(timeoutSec):
		_ = cmd.Process.Kill()
		<-done
		t.Fatalf("server kept running; startup should have been refused\n%s", out.String())
	}
	return 0, ""
}

// countMismatchFixture: the old-schema database plus a leftover `profiles` table in which
// u_alice has TWO owner rows (its one-owner index is a plain index of the same name, so the
// migration's CREATE UNIQUE INDEX IF NOT EXISTS is a no-op). The copy JOINs each old row to its
// account's owner, so u_alice's 3 progress / 2 watchlist rows come out as 6 / 4.
func countMismatchFixture(t *testing.T, owners int) (*sql.DB, string) {
	t.Helper()
	db, path := oldSchemaDB(t)
	stmts := []string{
		`CREATE TABLE profiles (
		  id TEXT PRIMARY KEY, user_id TEXT NOT NULL, name TEXT NOT NULL, avatar TEXT NOT NULL DEFAULT '',
		  max_age_level INTEGER NOT NULL DEFAULT 4, pin_hash TEXT, is_owner INTEGER NOT NULL DEFAULT 0,
		  created_at TEXT NOT NULL)`,
		`CREATE INDEX idx_profiles_one_owner ON profiles(user_id)`,
		`INSERT INTO profiles VALUES('p_alice_1','u_alice','Alice','',4,NULL,1,'2026-09-30T00:00:00Z')`,
	}
	if owners == 2 {
		stmts = append(stmts, `INSERT INTO profiles VALUES('p_alice_2','u_alice','Alice Two','',4,NULL,1,'2026-09-30T00:00:01Z')`)
	}
	for _, q := range stmts {
		if _, err := db.Exec(q); err != nil {
			t.Fatalf("fixture %q: %v", firstLine(q), err)
		}
	}
	return db, path
}

func openFresh(t *testing.T, path string) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", path+qaDSN)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

func profileRows(t *testing.T, db *sql.DB) []string {
	t.Helper()
	rows, err := db.Query(`SELECT id||'|'||user_id||'|'||name||'|'||is_owner FROM profiles ORDER BY id`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			t.Fatal(err)
		}
		out = append(out, s)
	}
	return out
}

var oc2107ProfilesBefore = []string{
	"p_alice_1|u_alice|Alice|1",
	"p_alice_2|u_alice|Alice Two|1",
}

// OC-2107 / FR-232. Given a pre-migration DB where the copy yields a per-account row-count
// mismatch (u_alice 3 -> 6 progress rows), when the migration runs, then it rolls back: the
// error names the account and both counts, the schema is byte-identical, the old tables hold
// exactly their literal rows, no progress_pre_profiles exists, no owner profile was added for
// bob/carol/dave (no partial assignment left authoritative), and the pre-migration copy exists.
// Red if: the per-account count verifier (sameCounts calls) is removed or stops comparing
// per account — the EXCEPT check alone passes this fixture and the migration would commit.
func TestOC2107_RowCountMismatchRollsBackTheWholeMigration(t *testing.T) {
	db, path := countMismatchFixture(t, 2)
	before := schemaDump(t, db)

	err := migrateProfiles(db, path)
	if err == nil {
		t.Fatalf("migration committed although u_alice's copy doubled her rows (count verifier not enforced)")
	}
	for _, w := range []string{
		"rolled back, old tables still authoritative",
		`progress row count mismatch for account "u_alice": 3 before, 6 after`,
	} {
		if !strings.Contains(err.Error(), w) {
			t.Errorf("error %q does not contain %q", err, w)
		}
	}

	fresh := openFresh(t, path) // observe through a new connection, not the migrating one
	if got := schemaDump(t, fresh); !reflect.DeepEqual(got, before) {
		t.Errorf("schema not restored:\nbefore %v\nafter  %v", before, got)
	}
	if hasColumn(t, fresh, "progress", "profile_id") {
		t.Errorf("progress left half-migrated (has profile_id)")
	}
	for _, tbl := range []string{"progress_pre_profiles", "watchlist_pre_profiles"} {
		var n int
		if err := fresh.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE name=?`, tbl).Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n != 0 {
			t.Errorf("%s exists after a rolled-back migration", tbl)
		}
	}
	if got := readProgress(t, fresh, "progress"); !reflect.DeepEqual(got, []qaProgressRow{
		{"m1", "u_alice", 120, 7200, "2026-09-01T10:00:00Z", 5},
		{"m2", "u_alice", 3000, 5400, "2026-09-02T11:30:00Z", 9},
		{"m3", "u_alice", 0, 100, "2026-09-03T00:00:00Z", 0},
		{"m1", "u_bob", 45, 7200, "2026-09-04T08:15:00Z", 11},
	}) {
		t.Errorf("progress changed (row or position): %+v", got)
	}
	if got := readWatchlist(t, fresh, "watchlist"); !reflect.DeepEqual(got, []qaWatchRow{
		{"m2", "u_alice", "2026-08-01T00:00:00Z"},
		{"m3", "u_alice", "2026-08-02T00:00:00Z"},
		{"m1", "u_carol", "2026-08-03T00:00:00Z"},
	}) {
		t.Errorf("watchlist changed: %+v", got)
	}
	if got := profileRows(t, fresh); !reflect.DeepEqual(got, oc2107ProfilesBefore) {
		t.Errorf("profiles = %v, want only the two pre-existing rows (no owner added for bob/carol/dave)", got)
	}
	bk := backups(t, path)
	if len(bk) != 1 {
		t.Fatalf("want exactly 1 pre-migration copy, found %d", len(bk))
	}
	copyDB := openFresh(t, bk[0])
	if got := len(readProgress(t, copyDB, "progress")); got != 4 {
		t.Errorf("pre-migration copy holds %d progress rows, want 4", got)
	}
}

// OC-2107 boundary / control: the same leftover profiles table with ONE owner row for u_alice
// migrates fine. Proves the refusal above comes from the duplicated copy, not from the
// fixture's leftover table. Red if the migration rejects any pre-existing profiles table.
func TestOC2107_SingleOwnerLeftoverTableMigrates(t *testing.T) {
	db, path := countMismatchFixture(t, 1)
	if err := migrateProfiles(db, path); err != nil {
		t.Fatalf("migration with one owner per account failed: %v", err)
	}
	fresh := openFresh(t, path)
	var aliceRows int
	if err := fresh.QueryRow(`SELECT COUNT(*) FROM progress WHERE profile_id='p_alice_1'`).Scan(&aliceRows); err != nil {
		t.Fatal(err)
	}
	if aliceRows != 3 {
		t.Errorf("u_alice's owner holds %d progress rows, want 3", aliceRows)
	}
}

// OC-2107 at the real entry point: the server binary on the mismatch database refuses to
// start (non-zero exit), logs the rollback and the mismatching account, and leaves the
// database unmigrated with its copy on disk. Never skipped (no privileges involved).
// Red if main() swallows migrateProfiles' error or the verifier is removed.
func TestOC2107_ServerRefusesToStartOnCountMismatch(t *testing.T) {
	bin := buildBackendBinary(t)
	db, path := countMismatchFixture(t, 2)
	before := schemaDump(t, db)
	db.Close()

	code, out := runBackendUntilExit(t, bin, path, 20)
	if code == 0 {
		t.Errorf("server exited 0 on a mismatching migration\n%s", out)
	}
	for _, w := range []string{"rolled back", `row count mismatch for account "u_alice"`} {
		if !strings.Contains(out, w) {
			t.Errorf("startup log does not contain %q:\n%s", w, out)
		}
	}
	fresh := openFresh(t, path)
	if got := schemaDump(t, fresh); !reflect.DeepEqual(got, before) {
		t.Errorf("database changed by the refused startup")
	}
	if got := len(readProgress(t, fresh, "progress")); got != 4 {
		t.Errorf("progress has %d rows after refused startup, want 4", got)
	}
	if n := len(backups(t, path)); n != 1 {
		t.Errorf("want 1 pre-migration copy, found %d", n)
	}
}

// AC-002-23 fallback injection exercised on every machine (the root path of the natural
// tests above otherwise runs only as root): an occupied copy name refuses the migration and
// changes nothing. Red if backupBeforeProfiles overwrites an existing copy.
func TestAC00223_ExistingCopyNameRefusesMigration(t *testing.T) {
	db, path := oldSchemaDB(t)
	before := schemaDump(t, db)
	occupyBackupNames(t, path, 30*time.Second)
	err := migrateProfiles(db, path)
	if err == nil {
		t.Fatalf("migration ran over an existing pre-migration copy")
	}
	for _, w := range []string{"migration not run", "already exists; refusing to overwrite"} {
		if !strings.Contains(err.Error(), w) {
			t.Errorf("error %q does not contain %q", err, w)
		}
	}
	if !reflect.DeepEqual(before, schemaDump(t, db)) {
		t.Errorf("schema changed despite the refused copy")
	}
	m, _ := filepath.Glob(path + ".pre-profiles-*.db")
	for _, f := range m {
		if b, _ := os.ReadFile(f); string(b) != "occupied by the test" {
			t.Errorf("existing copy %s was overwritten", f)
		}
	}
}
