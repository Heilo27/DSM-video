package main

// FRD-002 FR-232 [DESTRUCTIVE: production migration]: give every account an owner profile and
// re-key progress and watchlist from (item, account) to (item, profile).
//
// Safety envelope, in order:
//  1. A full copy of the database (VACUUM INTO) is written next to it first. If that fails,
//     nothing is touched and the error names the cause; main() exits with it (AC-002-23).
//  2. One transaction: rename the old tables, create the new ones, copy every row to its
//     account's owner profile, then prove the copy (per-account counts AND an EXCEPT that
//     finds any old row missing or changed). Any mismatch rolls everything back.
//  3. The old tables stay as progress_pre_profiles / watchlist_pre_profiles. Dropping them is
//     a separate, deliberate change in a later release.

import (
	"context"
	"crypto/rand"
	"database/sql"
	"fmt"
	"log"
	"math/big"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"
)

const profilesSchemaSQL = `
CREATE TABLE IF NOT EXISTS profiles (
  id            TEXT PRIMARY KEY,
  user_id       TEXT NOT NULL,
  name          TEXT NOT NULL,
  avatar        TEXT NOT NULL DEFAULT '',
  max_age_level INTEGER NOT NULL DEFAULT 4,
  pin_hash      TEXT,
  is_owner      INTEGER NOT NULL DEFAULT 0,
  created_at    TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_profiles_one_owner ON profiles(user_id) WHERE is_owner = 1;
CREATE UNIQUE INDEX IF NOT EXISTS idx_profiles_name ON profiles(user_id, name COLLATE NOCASE);
CREATE INDEX IF NOT EXISTS idx_profiles_user ON profiles(user_id);
`

// Per-profile tables. Index names carry a _v2 suffix so they can never collide with an index
// that travelled with a renamed pre-profiles table.
const profilesDataTablesSQL = `
CREATE TABLE progress (
  item_id          TEXT NOT NULL,
  user_id          TEXT NOT NULL,
  profile_id       TEXT NOT NULL,
  position_seconds INTEGER NOT NULL,
  duration_seconds INTEGER NOT NULL,
  updated_at       TEXT NOT NULL,
  write_seq        INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (item_id, profile_id)
);
CREATE INDEX idx_progress_profile_v2 ON progress(profile_id, updated_at);

CREATE TABLE watchlist (
  item_id    TEXT NOT NULL,
  user_id    TEXT NOT NULL,
  profile_id TEXT NOT NULL,
  added_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  PRIMARY KEY (item_id, profile_id)
);
CREATE INDEX idx_watchlist_profile_v2 ON watchlist(profile_id, added_at);
`

const profilesIndexesSQL = `
CREATE INDEX IF NOT EXISTS idx_progress_profile_v2 ON progress(profile_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_watchlist_profile_v2 ON watchlist(profile_id, added_at);
`

// backupMarginBytes is headroom on top of db+wal size: VACUUM INTO writes a compacted copy
// (normally smaller than db+wal), but the filesystem and the migration's own journal need
// room too, and a NAS volume at 100% is worse than a refused upgrade.
const backupMarginBytes = 16 << 20

// Test seams for AC-002-23. profilesFreeBytes reports free space for the directory holding
// the database; profilesBackup writes the pre-migration copy and returns its path. Replace
// either to force the failure path; the defaults are the production behaviour.
var (
	profilesFreeBytes = statfsFreeBytes
	profilesBackup    = backupBeforeProfiles
)

func statfsFreeBytes(dir string) (uint64, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(dir, &st); err != nil {
		return 0, err
	}
	return st.Bavail * uint64(st.Bsize), nil
}

func fileSize(path string) int64 {
	fi, err := os.Stat(path)
	if err != nil {
		return 0
	}
	return fi.Size()
}

// backupBeforeProfiles writes <dbPath>.pre-profiles-<UTC stamp>.db with VACUUM INTO. On any
// failure the partial file is removed and the returned error names the cause.
func backupBeforeProfiles(db *sql.DB, dbPath string) (string, error) {
	if dbPath == "" || dbPath == ":memory:" || strings.HasPrefix(dbPath, "file::memory:") {
		return "", fmt.Errorf("database path %q is not a file; cannot write the pre-migration copy", dbPath)
	}
	dir := filepath.Dir(dbPath)
	need := uint64(fileSize(dbPath)+fileSize(dbPath+"-wal")) + backupMarginBytes
	free, err := profilesFreeBytes(dir)
	if err != nil {
		return "", fmt.Errorf("cannot measure free space next to the database (%s): %w", dir, err)
	}
	if free < need {
		return "", fmt.Errorf("needs %d MB free next to the database (%s), %d MB available",
			(need+(1<<20)-1)>>20, dir, free>>20)
	}

	backup := dbPath + ".pre-profiles-" + time.Now().UTC().Format("20060102T150405Z") + ".db"
	if _, err := os.Stat(backup); err == nil {
		return "", fmt.Errorf("pre-migration copy %s already exists; refusing to overwrite it", backup)
	}
	if _, err := db.Exec(`VACUUM INTO ?`, backup); err != nil {
		_ = os.Remove(backup)
		return "", fmt.Errorf("writing pre-migration copy %s: %w", backup, err)
	}
	if fi, err := os.Stat(backup); err != nil || fi.Size() == 0 {
		_ = os.Remove(backup)
		return "", fmt.Errorf("pre-migration copy %s missing or empty after VACUUM INTO", backup)
	}
	return backup, nil
}

func tableExists(ctx context.Context, q interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}, name string) (bool, error) {
	var n int
	err := q.QueryRowContext(ctx, `SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?`, name).Scan(&n)
	return n > 0, err
}

func columnExists(ctx context.Context, db *sql.DB, table, col string) (bool, error) {
	var n int
	err := db.QueryRowContext(ctx, `SELECT COUNT(*) FROM pragma_table_info(?) WHERE name=?`, table, col).Scan(&n)
	return n > 0, err
}

// migrateProfiles runs after migrate(db). It is a no-op (beyond ensuring the profiles schema)
// once progress has a profile_id column. Any error is fatal at startup, and its text is the
// log line naming the cause (FR-232.1).
func migrateProfiles(db *sql.DB, dbPath string) error {
	ctx := context.Background()

	done, err := columnExists(ctx, db, "progress", "profile_id")
	if err != nil {
		return fmt.Errorf("profiles migration: inspecting progress: %w", err)
	}
	if done {
		if _, err := db.ExecContext(ctx, profilesSchemaSQL+profilesIndexesSQL); err != nil {
			return fmt.Errorf("profiles migration: ensuring profiles schema: %w", err)
		}
		return nil
	}

	// A renamed table already present while progress is still old-shape is a state this code
	// never produces (the rename and the new tables commit together). Stop rather than guess
	// which copy is authoritative, and never overwrite either.
	for _, t := range []string{"progress_pre_profiles", "watchlist_pre_profiles"} {
		exists, err := tableExists(ctx, db, t)
		if err != nil {
			return fmt.Errorf("profiles migration: inspecting %s: %w", t, err)
		}
		if exists {
			return fmt.Errorf("profiles migration: %s already exists but progress has no profile_id column; "+
				"unknown database state, migration not run (inspect the database and the .pre-profiles copies)", t)
		}
	}

	// Step 1: full copy first. Failure leaves the schema untouched.
	backup, err := profilesBackup(db, dbPath)
	if err != nil {
		return fmt.Errorf("profiles migration: backup failed, migration not run: %w", err)
	}
	log.Printf("profiles migration: pre-migration copy written to %s", backup)

	// Step 2: one transaction.
	summary, err := migrateProfilesTx(ctx, db)
	if err != nil {
		return fmt.Errorf("profiles migration: rolled back, old tables still authoritative (copy at %s): %w", backup, err)
	}
	log.Printf("profiles migration: done: %s", summary)
	return nil
}

type accountCounts map[string]int64

func countByAccount(ctx context.Context, tx *sql.Tx, table string) (accountCounts, error) {
	// table is one of this file's constants, never input.
	rows, err := tx.QueryContext(ctx, `SELECT user_id, COUNT(*) FROM `+table+` GROUP BY user_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := accountCounts{}
	for rows.Next() {
		var u string
		var n int64
		if err := rows.Scan(&u, &n); err != nil {
			return nil, err
		}
		out[u] = n
	}
	return out, rows.Err()
}

func migrateProfilesTx(ctx context.Context, db *sql.DB) (string, error) {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return "", fmt.Errorf("begin: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback()
		}
	}()

	if _, err := tx.ExecContext(ctx, profilesSchemaSQL); err != nil {
		return "", fmt.Errorf("creating profiles table: %w", err)
	}

	// Accounts: anyone with data in an account-keyed table. progress and watchlist rows are
	// taken whatever their user_id (even ''), because every one of them must land on an
	// owner profile or the copy check fails; settings' '' rows are server-global, not an
	// account, so the other tables contribute non-empty ids only.
	rows, err := tx.QueryContext(ctx, `
SELECT user_id FROM progress
UNION SELECT user_id FROM watchlist
UNION SELECT user_id FROM playlists WHERE user_id <> ''
UNION SELECT user_id FROM downloads WHERE user_id <> ''
UNION SELECT user_id FROM settings  WHERE user_id <> ''`)
	if err != nil {
		return "", fmt.Errorf("listing accounts: %w", err)
	}
	var accounts []string
	for rows.Next() {
		var u string
		if err := rows.Scan(&u); err != nil {
			rows.Close()
			return "", fmt.Errorf("listing accounts: %w", err)
		}
		accounts = append(accounts, u)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return "", fmt.Errorf("listing accounts: %w", err)
	}
	sort.Strings(accounts)

	now := time.Now().UTC().Format(time.RFC3339)
	for _, u := range accounts {
		var have int
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM profiles WHERE user_id=? AND is_owner=1`, u).Scan(&have); err != nil {
			return "", fmt.Errorf("checking owner for %s: %w", u, err)
		}
		if have > 0 {
			continue
		}
		id, err := newProfileID()
		if err != nil {
			return "", err
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO profiles(id, user_id, name, avatar, max_age_level, pin_hash, is_owner, created_at)
			 VALUES(?, ?, ?, '', 4, NULL, 1, ?)`,
			id, u, defaultOwnerName("", u), now); err != nil {
			return "", fmt.Errorf("creating owner profile for %s: %w", u, err)
		}
	}

	beforeProgress, err := countByAccount(ctx, tx, "progress")
	if err != nil {
		return "", fmt.Errorf("counting progress: %w", err)
	}
	beforeWatchlist, err := countByAccount(ctx, tx, "watchlist")
	if err != nil {
		return "", fmt.Errorf("counting watchlist: %w", err)
	}

	for _, stmt := range []string{
		`ALTER TABLE progress RENAME TO progress_pre_profiles`,
		`ALTER TABLE watchlist RENAME TO watchlist_pre_profiles`,
		profilesDataTablesSQL,
		`INSERT INTO progress(item_id, user_id, profile_id, position_seconds, duration_seconds, updated_at, write_seq)
		 SELECT o.item_id, o.user_id, p.id, o.position_seconds, o.duration_seconds, o.updated_at, o.write_seq
		 FROM progress_pre_profiles o JOIN profiles p ON p.user_id = o.user_id AND p.is_owner = 1`,
		`INSERT INTO watchlist(item_id, user_id, profile_id, added_at)
		 SELECT o.item_id, o.user_id, p.id, o.added_at
		 FROM watchlist_pre_profiles o JOIN profiles p ON p.user_id = o.user_id AND p.is_owner = 1`,
	} {
		if _, err := tx.ExecContext(ctx, stmt); err != nil {
			return "", fmt.Errorf("%s: %w", firstLine(stmt), err)
		}
	}

	afterProgress, err := countByAccount(ctx, tx, "progress")
	if err != nil {
		return "", fmt.Errorf("recounting progress: %w", err)
	}
	afterWatchlist, err := countByAccount(ctx, tx, "watchlist")
	if err != nil {
		return "", fmt.Errorf("recounting watchlist: %w", err)
	}
	if err := sameCounts("progress", beforeProgress, afterProgress); err != nil {
		return "", err
	}
	if err := sameCounts("watchlist", beforeWatchlist, afterWatchlist); err != nil {
		return "", err
	}

	// Counts can match while values differ; prove every old row exists unchanged.
	for _, check := range []struct{ table, sql string }{
		{"progress", `SELECT COUNT(*) FROM (
			SELECT item_id, user_id, position_seconds, duration_seconds, updated_at, write_seq FROM progress_pre_profiles
			EXCEPT
			SELECT item_id, user_id, position_seconds, duration_seconds, updated_at, write_seq FROM progress)`},
		{"watchlist", `SELECT COUNT(*) FROM (
			SELECT item_id, user_id, added_at FROM watchlist_pre_profiles
			EXCEPT
			SELECT item_id, user_id, added_at FROM watchlist)`},
	} {
		var missing int64
		if err := tx.QueryRowContext(ctx, check.sql).Scan(&missing); err != nil {
			return "", fmt.Errorf("verifying %s copy: %w", check.table, err)
		}
		if missing != 0 {
			return "", fmt.Errorf("%s copy check failed: %d pre-migration rows missing or changed in the new table", check.table, missing)
		}
	}

	if err := tx.Commit(); err != nil {
		return "", fmt.Errorf("commit: %w", err)
	}
	committed = true
	return fmt.Sprintf("%d accounts, %d progress rows, %d watchlist rows assigned to owner profiles",
		len(accounts), sumCounts(afterProgress), sumCounts(afterWatchlist)), nil
}

func sameCounts(table string, before, after accountCounts) error {
	keys := map[string]bool{}
	for k := range before {
		keys[k] = true
	}
	for k := range after {
		keys[k] = true
	}
	sorted := make([]string, 0, len(keys))
	for k := range keys {
		sorted = append(sorted, k)
	}
	sort.Strings(sorted)
	for _, k := range sorted {
		if before[k] != after[k] {
			return fmt.Errorf("%s row count mismatch for account %q: %d before, %d after", table, k, before[k], after[k])
		}
	}
	return nil
}

func sumCounts(c accountCounts) int64 {
	var n int64
	for _, v := range c {
		n += v
	}
	return n
}

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

const base62 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

// newProfileID returns "pf_" + 10 random base62 characters (~59 bits).
func newProfileID() (string, error) {
	var b strings.Builder
	b.WriteString("pf_")
	max := big.NewInt(int64(len(base62)))
	for i := 0; i < 10; i++ {
		n, err := rand.Int(rand.Reader, max)
		if err != nil {
			return "", fmt.Errorf("profile id: %w", err)
		}
		b.WriteByte(base62[n.Int64()])
	}
	return b.String(), nil
}

const maxProfileNameRunes = 20

// truncateRunes cuts s to at most n runes.
func truncateRunes(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	r := []rune(s)
	return string(r[:n])
}

// defaultOwnerName is the owner profile's starting name (FR-204): the DSM display name when
// known, else the account's username part, else "Owner"; trimmed to the 20-rune limit.
func defaultOwnerName(displayName, userID string) string {
	for _, c := range []string{displayName, strings.TrimPrefix(userID, "u_")} {
		if c = strings.TrimSpace(truncateRunes(strings.TrimSpace(c), maxProfileNameRunes)); c != "" {
			return c
		}
	}
	return "Owner"
}
