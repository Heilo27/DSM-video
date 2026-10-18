package sqltx

import (
	"context"
	"database/sql"
	"errors"
	"path/filepath"
	"strings"
	"testing"
	"time"

	_ "modernc.org/sqlite"
)

// openDB returns a database whose connections enforce foreign keys, with a child table whose
// deferred FK makes COMMIT fail on demand. SQLite documents that a COMMIT failing on a
// deferred constraint leaves the transaction open: the state the package exists to clean up.
// busy_timeout is short so a held write lock shows up as an error rather than a long wait.
func openDB(t *testing.T, maxConns int) (*sql.DB, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "tx.db")
	db, err := sql.Open("sqlite", path+"?_pragma=foreign_keys(1)&_pragma=busy_timeout(1000)&_pragma=journal_mode(WAL)")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	db.SetMaxOpenConns(maxConns)
	for _, stmt := range []string{
		`CREATE TABLE parent (id TEXT PRIMARY KEY)`,
		`CREATE TABLE child (id TEXT PRIMARY KEY, parent_id TEXT REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED)`,
		`CREATE TABLE kv (k TEXT PRIMARY KEY)`,
	} {
		if _, err := db.Exec(stmt); err != nil {
			t.Fatalf("schema: %v", err)
		}
	}
	return db, path
}

func orphan(tx *sql.Tx) error {
	_, err := tx.Exec(`INSERT INTO child(id, parent_id) VALUES ('c', 'missing')`)
	return err
}

func put(k string) func(tx *sql.Tx) error {
	return func(tx *sql.Tx) error {
		_, err := tx.Exec(`INSERT INTO kv(k) VALUES (?)`, k)
		return err
	}
}

func bounded(t *testing.T, what string, fn func()) {
	t.Helper()
	done := make(chan struct{})
	go func() { defer close(done); fn() }()
	select {
	case <-done:
	case <-time.After(15 * time.Second):
		t.Fatalf("%s did not return within 15s (deadlocked on a held write lock)", what)
	}
}

// assertLockFree: a write through the same pool (with one connection, necessarily the one
// the failed transaction used) and a write from an independent connection both succeed.
func assertLockFree(t *testing.T, db *sql.DB, path, k string) {
	t.Helper()
	bounded(t, "follow-up writes", func() {
		if err := Run(context.Background(), db, put(k)); err != nil {
			t.Errorf("write through the pool after the failure: %v", err)
		}
		other, err := sql.Open("sqlite", path+"?_pragma=busy_timeout(1000)")
		if err != nil {
			t.Errorf("open: %v", err)
			return
		}
		defer other.Close()
		if _, err := other.Exec(`INSERT INTO kv(k) VALUES (?)`, k+"-other"); err != nil {
			t.Errorf("independent writer after the failure (write lock still held): %v", err)
		}
	})
}

func TestCommitFailureReleasesWriteLock(t *testing.T) {
	for _, conns := range []int{1, 4} {
		db, path := openDB(t, conns)
		err := Run(context.Background(), db, orphan)
		if err == nil || !strings.Contains(strings.ToLower(err.Error()), "foreign key") {
			t.Fatalf("conns=%d: want a FOREIGN KEY commit failure, got %v", conns, err)
		}
		assertLockFree(t, db, path, "after")
		var n int
		if err := db.QueryRow(`SELECT COUNT(*) FROM child`).Scan(&n); err != nil || n != 0 {
			t.Fatalf("conns=%d: failed commit's row is visible: n=%d err=%v", conns, n, err)
		}
	}
}

// More failures than the pool has connections: none may be kept.
func TestRepeatedCommitFailuresDoNotExhaustPool(t *testing.T) {
	db, path := openDB(t, 2)
	for i := 0; i < 5; i++ {
		bounded(t, "failing write", func() {
			if err := Run(context.Background(), db, orphan); err == nil {
				t.Errorf("failure %d committed", i)
			}
		})
	}
	assertLockFree(t, db, path, "after")
}

func TestPanicRollsBackAndReleases(t *testing.T) {
	db, path := openDB(t, 1)
	func() {
		defer func() {
			if recover() == nil {
				t.Fatal("no panic")
			}
		}()
		_ = Run(context.Background(), db, func(tx *sql.Tx) error {
			if err := put("half")(tx); err != nil {
				return err
			}
			panic("boom")
		})
	}()
	assertLockFree(t, db, path, "after")
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM kv WHERE k = 'half'`).Scan(&n); err != nil || n != 0 {
		t.Fatalf("panicked write survived: n=%d err=%v", n, err)
	}
}

func TestErrorRollsBackAndReleases(t *testing.T) {
	db, path := openDB(t, 1)
	sentinel := errors.New("stop")
	err := Run(context.Background(), db, func(tx *sql.Tx) error {
		if err := put("half")(tx); err != nil {
			return err
		}
		return sentinel
	})
	if !errors.Is(err, sentinel) {
		t.Fatalf("want the write's own error, got %v", err)
	}
	assertLockFree(t, db, path, "after")
}

// A context cancelled before Commit: database/sql refuses the commit without finishing the
// Tx. The transaction must still end and the connection come back.
func TestCancelledContextAtCommitReleases(t *testing.T) {
	db, path := openDB(t, 1)
	ctx, cancel := context.WithCancel(context.Background())
	tx, err := Begin(ctx, db)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Close()
	if err := put("x")(tx.Tx); err != nil {
		t.Fatal(err)
	}
	cancel()
	if err := tx.Commit(); err == nil {
		t.Fatal("commit under a cancelled context succeeded")
	}
	assertLockFree(t, db, path, "after")
}

// Commit, Rollback and Close in any order: Close stays safe to defer.
func TestCloseIsIdempotent(t *testing.T) {
	db, path := openDB(t, 1)
	tx, err := Begin(context.Background(), db)
	if err != nil {
		t.Fatal(err)
	}
	if err := put("a")(tx.Tx); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	tx.Close()
	tx.Close()
	if err := tx.Rollback(); !errors.Is(err, sql.ErrTxDone) {
		t.Fatalf("Rollback after Commit: %v, want ErrTxDone", err)
	}
	assertLockFree(t, db, path, "after")
}
