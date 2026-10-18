package main

// FRD-002 FR-232 / AC-002-22: rehearse the startup migration on a COPY of a real database,
// timed. Skips unless DSVIDEO_PRODCOPY_DB names the copy. The file is migrated IN PLACE (and
// the FR-232 pre-migration copy is written next to it), so point it at a throwaway copy, never
// at a live database. Run:
//
//	DSVIDEO_PRODCOPY_DB=/path/to/throwaway.db go test -run TestProdCopyProfilesMigration -v -count=1 .
//
// It opens the file exactly as main() does (same DSN, pool size and PRAGMAs), runs migrate()
// then migrateProfiles(), and reports wall time per step, peak RSS, row counts for every table
// before and after, the migration's own verifier result (its log line), an independent
// value check against the renamed pre-profiles tables, idempotence, and PRAGMA integrity_check.

import (
	"bytes"
	"context"
	"database/sql"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"syscall"
	"testing"
	"time"
)

func prodCopyTableCounts(t *testing.T, db *sql.DB) map[string]int64 {
	t.Helper()
	rows, err := db.Query(`SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'`)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for rows.Next() {
		var n string
		if err := rows.Scan(&n); err != nil {
			t.Fatal(err)
		}
		names = append(names, n)
	}
	rows.Close()
	out := map[string]int64{}
	for _, n := range names {
		var c int64
		if err := db.QueryRow(`SELECT COUNT(*) FROM "` + n + `"`).Scan(&c); err != nil {
			t.Fatal(err)
		}
		out[n] = c
	}
	return out
}

func prodCopyGroup(t *testing.T, db *sql.DB, q string) []string {
	t.Helper()
	rows, err := db.Query(q)
	if err != nil {
		t.Fatalf("%s: %v", q, err)
	}
	defer rows.Close()
	cols, _ := rows.Columns()
	var out []string
	for rows.Next() {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			t.Fatal(err)
		}
		parts := make([]string, len(vals))
		for i, v := range vals {
			if b, ok := v.([]byte); ok {
				v = string(b)
			}
			parts[i] = fmt.Sprint(v)
		}
		out = append(out, strings.Join(parts, "|"))
	}
	return out
}

func prodCopyMaxRSSMB() float64 {
	var ru syscall.Rusage
	if err := syscall.Getrusage(syscall.RUSAGE_SELF, &ru); err != nil {
		return -1
	}
	if runtime.GOOS == "darwin" {
		return float64(ru.Maxrss) / (1 << 20) // bytes
	}
	return float64(ru.Maxrss) / 1024 // Linux: KiB
}

func TestProdCopyProfilesMigration(t *testing.T) {
	path := os.Getenv("DSVIDEO_PRODCOPY_DB")
	if path == "" {
		t.Skip("DSVIDEO_PRODCOPY_DB not set; this rehearsal needs a throwaway copy of a real database")
	}
	if strings.Contains(path, "/var/packages/") || strings.Contains(path, "/volume") {
		t.Fatalf("refusing %s: that looks like a live NAS path; pass a throwaway copy", path)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatal(err)
	}
	preExisting, _ := filepath.Glob(path + ".pre-profiles-*.db")

	var logBuf bytes.Buffer
	log.SetOutput(io.MultiWriter(os.Stderr, &logBuf))
	t.Cleanup(func() { log.SetOutput(os.Stderr) })

	rssStart := prodCopyMaxRSSMB()
	tOpen := time.Now()
	// Same open sequence as main().
	db, err := sql.Open("sqlite", path+"?_pragma=busy_timeout(30000)&_pragma=journal_mode(WAL)&_pragma=synchronous(1)&_pragma=wal_autocheckpoint(500)")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	db.SetMaxOpenConns(16)
	db.SetMaxIdleConns(4)
	if _, err := db.Exec("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=500; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=30000"); err != nil {
		t.Fatal(err)
	}
	dOpen := time.Since(tOpen)

	alreadyMigrated, err := columnExists(context.Background(), db, "progress", "profile_id")
	if err != nil {
		t.Fatal(err)
	}
	before := prodCopyTableCounts(t, db)
	beforeAcct := prodCopyGroup(t, db, `SELECT 'progress', user_id, COUNT(*) FROM progress GROUP BY user_id
		UNION ALL SELECT 'watchlist', user_id, COUNT(*) FROM watchlist GROUP BY user_id ORDER BY 1, 2`)

	t0 := time.Now()
	if err := migrate(db); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	dMigrate := time.Since(t0)
	t1 := time.Now()
	errProfiles := migrateProfiles(db, path)
	dProfiles := time.Since(t1)
	if errProfiles != nil {
		t.Fatalf("migrateProfiles: %v (after %v)", errProfiles, dProfiles)
	}

	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	after := prodCopyTableCounts(t, db)
	afterAcct := prodCopyGroup(t, db, `SELECT 'progress', user_id, COUNT(*) FROM progress GROUP BY user_id
		UNION ALL SELECT 'watchlist', user_id, COUNT(*) FROM watchlist GROUP BY user_id ORDER BY 1, 2`)
	profiles := prodCopyGroup(t, db, `SELECT user_id, name, is_owner, max_age_level, pin_hash IS NULL FROM profiles ORDER BY user_id`)

	// Independent check, both directions: every row is on its account's owner profile with
	// identical values, and no extra rows exist.
	var mis [4]int64
	for i, q := range []string{
		`SELECT COUNT(*) FROM (SELECT item_id,user_id,position_seconds,duration_seconds,updated_at,write_seq FROM progress_pre_profiles
		  EXCEPT SELECT item_id,user_id,position_seconds,duration_seconds,updated_at,write_seq FROM progress)`,
		`SELECT COUNT(*) FROM (SELECT item_id,user_id,position_seconds,duration_seconds,updated_at,write_seq FROM progress
		  EXCEPT SELECT item_id,user_id,position_seconds,duration_seconds,updated_at,write_seq FROM progress_pre_profiles)`,
		`SELECT (SELECT COUNT(*) FROM (SELECT item_id,user_id,added_at FROM watchlist_pre_profiles EXCEPT SELECT item_id,user_id,added_at FROM watchlist))
		      + (SELECT COUNT(*) FROM (SELECT item_id,user_id,added_at FROM watchlist EXCEPT SELECT item_id,user_id,added_at FROM watchlist_pre_profiles))`,
		`SELECT (SELECT COUNT(*) FROM progress x LEFT JOIN profiles p ON p.id=x.profile_id AND p.user_id=x.user_id AND p.is_owner=1 WHERE p.id IS NULL)
		      + (SELECT COUNT(*) FROM watchlist x LEFT JOIN profiles p ON p.id=x.profile_id AND p.user_id=x.user_id AND p.is_owner=1 WHERE p.id IS NULL)`,
	} {
		if alreadyMigrated && i < 3 {
			continue
		}
		if err := db.QueryRow(q).Scan(&mis[i]); err != nil {
			t.Fatalf("independent check %d: %v", i, err)
		}
	}
	var owners, accounts int64
	_ = db.QueryRow(`SELECT COUNT(*) FROM profiles WHERE is_owner=1`).Scan(&owners)
	_ = db.QueryRow(`SELECT COUNT(DISTINCT user_id) FROM profiles`).Scan(&accounts)

	// Idempotence: a second startup must be a no-op and must not write another copy.
	t2 := time.Now()
	if err := migrateProfiles(db, path); err != nil {
		t.Fatalf("second migrateProfiles: %v", err)
	}
	dSecond := time.Since(t2)
	backups, _ := filepath.Glob(path + ".pre-profiles-*.db")
	var integrity []string
	integrity = prodCopyGroup(t, db, `PRAGMA integrity_check`)
	fk := prodCopyGroup(t, db, `PRAGMA foreign_key_check`)

	names := map[string]bool{}
	for k := range before {
		names[k] = true
	}
	for k := range after {
		names[k] = true
	}
	var sorted []string
	for k := range names {
		sorted = append(sorted, k)
	}
	sort.Strings(sorted)

	t.Logf("already migrated before run: %v", alreadyMigrated)
	t.Logf("timing: open %v | migrate() %v | migrateProfiles() %v | total %v | second startup %v",
		dOpen, dMigrate, dProfiles, dOpen+dMigrate+dProfiles, dSecond)
	t.Logf("peak RSS: start %.1f MB, end %.1f MB (getrusage); Go heap sys %.1f MB, total alloc %.1f MB",
		rssStart, prodCopyMaxRSSMB(), float64(ms.HeapSys)/(1<<20), float64(ms.TotalAlloc)/(1<<20))
	for _, k := range sorted {
		b, okb := before[k]
		a, oka := after[k]
		bs, as := fmt.Sprint(b), fmt.Sprint(a)
		if !okb {
			bs = "-"
		}
		if !oka {
			as = "-"
		}
		t.Logf("rows %-24s before %6s after %6s", k, bs, as)
	}
	t.Logf("per account before: %v", beforeAcct)
	t.Logf("per account after:  %v", afterAcct)
	t.Logf("profiles: %v (owners %d, accounts %d)", profiles, owners, accounts)
	t.Logf("independent check: progress old-new %d, new-old %d, watchlist both ways %d, rows off owner %d", mis[0], mis[1], mis[2], mis[3])
	t.Logf("pre-migration copies: %v (pre-existing %v)", backups, preExisting)
	t.Logf("integrity_check: %v; foreign_key_check rows: %d", integrity, len(fk))
	for _, l := range strings.Split(strings.TrimSpace(logBuf.String()), "\n") {
		if strings.Contains(l, "profiles migration") {
			t.Logf("migration log: %s", l)
		}
	}

	for i, n := range mis {
		if n != 0 {
			t.Errorf("independent check %d found %d mismatched rows", i, n)
		}
	}
	if len(integrity) != 1 || integrity[0] != "ok" {
		t.Errorf("integrity_check: %v", integrity)
	}
	if owners != accounts {
		t.Errorf("owners %d != accounts %d", owners, accounts)
	}
	if !alreadyMigrated && len(backups) != len(preExisting)+1 {
		t.Errorf("expected exactly one new pre-migration copy, have %v (pre-existing %v)", backups, preExisting)
	}
}
