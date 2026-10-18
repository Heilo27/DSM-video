package main

// TASK-941 part 2: a transaction whose COMMIT fails must not leave SQLite's write lock held.
//
// database/sql marks a Tx finished before it asks the driver to commit, and the modernc
// driver's Commit only runs COMMIT. When SQLite refuses the COMMIT and keeps the transaction
// open (SQLITE_BUSY, a deferred constraint), the deferred tx.Rollback() is a no-op
// (ErrTxDone) and the connection goes back to the pool still inside its write transaction.
// Every later writer then waits out busy_timeout and fails, and the pooled connection itself
// refuses BEGIN ("cannot start a transaction within a transaction").
//
// The commit failure is injected with a deferred foreign key: SQLite checks it at COMMIT,
// fails the COMMIT, and documents that the transaction stays open, which is exactly the
// state the bug leaves behind.

import (
	"context"
	"database/sql"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const txFailSeqStart = 10

// newCommitFailServer returns a Server over a database whose connections enforce foreign
// keys, with progress_seq at txFailSeqStart and a deferred-FK child table that makes COMMIT
// fail on demand. busy_timeout is short so a held write lock shows up as an error, not a hang.
func newCommitFailServer(t *testing.T) (*Server, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "commitfail.db")
	db, err := sql.Open("sqlite", path+"?_pragma=foreign_keys(1)&_pragma=busy_timeout(1000)&_pragma=journal_mode(WAL)")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	db.SetMaxOpenConns(4)
	for _, stmt := range []string{
		`CREATE TABLE sync_state (key TEXT PRIMARY KEY, value INTEGER NOT NULL)`,
		fmt.Sprintf(`INSERT INTO sync_state(key, value) VALUES ('progress_seq', %d), ('item_seq', %d)`, txFailSeqStart, txFailSeqStart),
		`CREATE TABLE parent (id TEXT PRIMARY KEY)`,
		`CREATE TABLE child (id TEXT PRIMARY KEY, parent_id TEXT REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED)`,
		`CREATE TABLE kv (k TEXT PRIMARY KEY, seq INTEGER NOT NULL)`,
	} {
		if _, err := db.Exec(stmt); err != nil {
			t.Fatalf("schema %q: %v", stmt, err)
		}
	}
	return &Server{db: db}, path
}

// orphanChild is a write whose statements succeed but whose COMMIT fails.
func orphanChild(tx *sql.Tx, seq int64) error {
	_, err := tx.Exec(`INSERT INTO child(id, parent_id) VALUES (?, 'no-such-parent')`, fmt.Sprint("c", seq))
	return err
}

func putKV(k string) func(tx *sql.Tx, seq int64) error {
	return func(tx *sql.Tx, seq int64) error {
		_, err := tx.Exec(`INSERT INTO kv(k, seq) VALUES (?, ?)`, k, seq)
		return err
	}
}

// withDeadline fails the test instead of hanging if fn deadlocks.
func withDeadline(t *testing.T, what string, fn func()) {
	t.Helper()
	done := make(chan struct{})
	go func() { defer close(done); fn() }()
	select {
	case <-done:
	case <-time.After(15 * time.Second):
		t.Fatalf("%s did not return within 15s: deadlocked on a held write lock", what)
	}
}

// assertWritesStillWork proves the write lock is free: several writes through the server's
// pool (which reuses the connection the failed transaction ran on), then a write from an
// independent connection, which would wait out busy_timeout against a held lock.
func assertWritesStillWork(t *testing.T, s *Server, path string, wantFirst int64) {
	t.Helper()
	withDeadline(t, "follow-up writes", func() {
		for i := int64(0); i < 3; i++ {
			seq, err := s.writeWithSeq(context.Background(), "progress_seq", putKV(fmt.Sprint("k", i)))
			if err != nil {
				t.Errorf("write %d after the failed commit: %v", i, err)
				return
			}
			if want := wantFirst + i; seq != want {
				t.Errorf("write %d committed seq %d, want %d (the failed transaction's allocation must roll back)", i, seq, want)
			}
		}
		other, err := sql.Open("sqlite", path+"?_pragma=busy_timeout(1000)")
		if err != nil {
			t.Errorf("open second writer: %v", err)
			return
		}
		defer other.Close()
		if _, err := other.Exec(`INSERT INTO kv(k, seq) VALUES ('other', 0)`); err != nil {
			t.Errorf("independent writer blocked after the failed commit (write lock still held): %v", err)
		}
	})
	if got := s.cachedProgressSeq.Load(); got != wantFirst+2 {
		t.Errorf("published progress_seq = %d, want %d", got, wantFirst+2)
	}
}

func TestWriteWithSeqCommitFailureReleasesWriteLock(t *testing.T) {
	s, path := newCommitFailServer(t)

	seq, err := s.writeWithSeq(context.Background(), "progress_seq", orphanChild)
	if err == nil || !strings.Contains(strings.ToLower(err.Error()), "foreign key") {
		t.Fatalf("injected commit failure: got seq=%d err=%v, want a FOREIGN KEY commit error", seq, err)
	}
	if got := s.cachedProgressSeq.Load(); got != 0 {
		t.Fatalf("a failed commit published progress_seq %d", got)
	}
	assertWritesStillWork(t, s, path, txFailSeqStart+1)
}

// The same guarantee for every failure in a row: repeated commit failures must not use up
// the pool's connections one leaked transaction at a time.
func TestWriteWithSeqRepeatedCommitFailuresDoNotExhaustPool(t *testing.T) {
	s, path := newCommitFailServer(t)
	for i := 0; i < 6; i++ { // more than SetMaxOpenConns(4)
		withDeadline(t, "failing write", func() {
			if _, err := s.writeWithSeq(context.Background(), "progress_seq", orphanChild); err == nil {
				t.Errorf("failing write %d committed", i)
			}
		})
	}
	assertWritesStillWork(t, s, path, txFailSeqStart+1)
}

func TestWriteWithSeqPanicReleasesWriteLock(t *testing.T) {
	s, path := newCommitFailServer(t)
	func() {
		defer func() {
			if recover() == nil {
				t.Fatalf("write did not panic")
			}
		}()
		_, _ = s.writeWithSeq(context.Background(), "progress_seq", func(tx *sql.Tx, seq int64) error {
			if err := putKV("half")(tx, seq); err != nil {
				return err
			}
			panic("write panicked mid-transaction")
		})
	}()
	assertWritesStillWork(t, s, path, txFailSeqStart+1)
	var n int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM kv WHERE k = 'half'`).Scan(&n); err != nil || n != 0 {
		t.Fatalf("panicked write's row survived: n=%d err=%v", n, err)
	}
}

// writeWithItemSeq is the item_seq face of the same helper.
func TestWriteWithItemSeqCommitFailureReleasesWriteLock(t *testing.T) {
	s, path := newCommitFailServer(t)
	if _, err := s.writeWithItemSeq(context.Background(), orphanChild); err == nil {
		t.Fatalf("injected commit failure committed")
	}
	if got := s.cachedItemSeq.Load(); got != 0 {
		t.Fatalf("a failed commit published item_seq %d", got)
	}
	seq, err := s.writeWithItemSeq(context.Background(), putKV("item"))
	if err != nil || seq != txFailSeqStart+1 {
		t.Fatalf("item write after failed commit: seq=%d err=%v, want %d", seq, err, txFailSeqStart+1)
	}
	assertWritesStillWork(t, s, path, txFailSeqStart+1)
}
