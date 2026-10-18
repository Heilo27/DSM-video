// Package sqltx is the one home for opening, committing and abandoning a database
// transaction so that SQLite's write lock is released on every path (TASK-941).
//
// The problem it exists for: database/sql marks a *sql.Tx finished BEFORE it asks the driver
// to commit, and the modernc.org/sqlite driver's Commit only runs COMMIT. When SQLite refuses
// the COMMIT but keeps the transaction open, which it documents for SQLITE_BUSY and for a
// deferred constraint failing at COMMIT, and which can happen for SQLITE_FULL/IOERR, the
// caller's deferred tx.Rollback() returns sql.ErrTxDone without sending ROLLBACK, and
// database/sql hands the connection back to the pool still inside its write transaction.
// From then on every other writer waits out busy_timeout and fails, and the pooled
// connection itself refuses BEGIN, until that connection happens to be closed.
//
// After a failed Commit, database/sql offers no handle on that connection. So Begin pins
// one (*sql.Conn) for the transaction's life. A failed Commit sends ROLLBACK on the same
// connection and then discards it, so the pool never sees it again. Rollback and Close
// release the pinned connection too, and Close is safe to defer, so an early return or a
// panic leaves no transaction and no connection behind.
package sqltx

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"fmt"
)

// Tx is a *sql.Tx on a connection pinned for its lifetime. Use it like a *sql.Tx (it embeds
// one; pass tx.Tx where a *sql.Tx is wanted) and always `defer tx.Close()`.
type Tx struct {
	*sql.Tx
	conn *sql.Conn
}

// Begin pins a connection from db and starts a transaction on it.
func Begin(ctx context.Context, db *sql.DB) (*Tx, error) {
	conn, err := db.Conn(ctx)
	if err != nil {
		return nil, err
	}
	tx, err := conn.BeginTx(ctx, nil)
	if err != nil {
		_ = conn.Close()
		return nil, err
	}
	return &Tx{Tx: tx, conn: conn}, nil
}

// Commit commits and releases the connection. If the commit fails, the transaction is rolled
// back on the same connection and the connection is discarded, so the write lock is released
// whatever state SQLite left the transaction in. The commit error is returned.
func (t *Tx) Commit() error {
	err := t.Tx.Commit()
	if err != nil {
		// The context may be why Commit failed (database/sql then leaves the Tx open), so
		// abandon it through the Tx first; this is a no-op returning ErrTxDone otherwise.
		_ = t.Tx.Rollback()
		t.discardConn()
	}
	t.release()
	return err
}

// Rollback rolls back and releases the connection.
func (t *Tx) Rollback() error {
	err := t.Tx.Rollback()
	t.release()
	return err
}

// Close rolls back if the transaction is still open and releases the connection. It is
// idempotent and safe after Commit or Rollback; defer it straight after Begin.
func (t *Tx) Close() {
	_ = t.Tx.Rollback()
	t.release()
}

// discardConn ends any transaction SQLite may still hold on the pinned connection and makes
// the pool close that connection rather than reuse it. Closing a SQLite connection also rolls
// back anything still open, so the ROLLBACK is belt and braces. A background context: the
// caller's may be the reason we are here, and a cancelled context would skip the ROLLBACK.
func (t *Tx) discardConn() {
	if t.conn == nil {
		return
	}
	_, _ = t.conn.ExecContext(context.Background(), "ROLLBACK")
	// Returning driver.ErrBadConn from Raw makes database/sql close the connection
	// instead of returning it to the pool.
	_ = t.conn.Raw(func(any) error { return driver.ErrBadConn })
}

func (t *Tx) release() {
	if t.conn == nil {
		return
	}
	_ = t.conn.Close()
	t.conn = nil
}

// Run runs fn inside a transaction and commits it if fn returns nil. Any error from fn, and
// any panic, rolls back; a failed commit is handled as Commit describes.
func Run(ctx context.Context, db *sql.DB, fn func(tx *sql.Tx) error) error {
	tx, err := Begin(ctx, db)
	if err != nil {
		return err
	}
	defer tx.Close()
	if err := fn(tx.Tx); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit: %w", err)
	}
	return nil
}
