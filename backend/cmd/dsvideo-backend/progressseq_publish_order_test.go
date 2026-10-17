package main

// TASK-919 item 7: a progress_seq is advertised on the heartbeat only once the progress
// change it numbers is committed, and no later progress_seq can commit while that change is
// still being written.
//
// A device compares the heartbeat's progressSeq to its cursor; on a change it fetches
// /progress/all and stores the new number as its cursor. If the number is visible before
// the row, the device fetches the old position, records the new number, and keeps the stale
// position until some unrelated progress write bumps the counter again.
//
// The observation point is a SQLite trigger on the progress table that fires INSIDE the
// writing transaction, after the row is written but before commit (the same technique as
// itemseq_publish_order_test.go, whose dsv_test_observe_seq registration this file shares).
// At that instant it records:
//   - published: what the heartbeat would advertise right now (getSyncSeqs);
//   - committed: progress_seq as a SECOND connection sees it. If it has already moved, the
//     allocation committed on its own and another writer could commit and publish a higher
//     number before this row lands.
// Both must still read the starting value. After the write both read start+1, and the row
// carries start+1 as its write_seq.

import (
	"database/sql"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"
)

const progressSeqStart = 40

type progressSeqEnv struct {
	*qaEnv
	reader *sql.DB
	obs    []seqObservation
}

// newProgressSeqEnv builds a server whose connections all carry dsv_test_observe_seq, with
// progress_seq committed and published at progressSeqStart and item w1 in the library.
func newProgressSeqEnv(t *testing.T) *progressSeqEnv {
	t.Helper()
	registerSeqObserver(t) // before any connection of this test's DB is opened
	e := &progressSeqEnv{qaEnv: newQAEnv(t)}
	reader, err := sql.Open("sqlite", e.dbPath+"?_pragma=busy_timeout(30000)")
	if err != nil {
		t.Fatalf("open reader: %v", err)
	}
	t.Cleanup(func() { reader.Close() })
	e.reader = reader
	if _, err := e.db.Exec(`UPDATE sync_state SET value = ? WHERE key = 'progress_seq'`, progressSeqStart); err != nil {
		t.Fatalf("seed progress_seq: %v", err)
	}
	e.s.cachedProgressSeq.Store(progressSeqStart)
	e.seedItem("w1", "Drama", sp("PG"))

	seqObserver.mu.Lock()
	seqObserver.fn = func(rowSeq int64) {
		_, published := e.s.getSyncSeqs()
		var committed int64
		if err := e.reader.QueryRow(`SELECT value FROM sync_state WHERE key = 'progress_seq'`).Scan(&committed); err != nil {
			t.Errorf("reader: %v", err)
		}
		e.obs = append(e.obs, seqObservation{rowSeq: rowSeq, published: published, committed: committed})
	}
	seqObserver.mu.Unlock()
	t.Cleanup(func() {
		seqObserver.mu.Lock()
		seqObserver.fn = nil
		seqObserver.mu.Unlock()
	})
	return e
}

func (e *progressSeqEnv) exec(stmt string) {
	e.t.Helper()
	if _, err := e.db.Exec(stmt); err != nil {
		e.t.Fatalf("%s: %v", stmt, err)
	}
}

// observe fires the observer on every progress row written or deleted. Inserts and updates
// report the row's write_seq; deletes report progress_seq as the writing transaction sees it.
func (e *progressSeqEnv) observe() {
	e.exec(`CREATE TRIGGER obs_progress_ins AFTER INSERT ON progress BEGIN SELECT dsv_test_observe_seq(NEW.write_seq); END`)
	e.exec(`CREATE TRIGGER obs_progress_upd AFTER UPDATE ON progress BEGIN SELECT dsv_test_observe_seq(NEW.write_seq); END`)
	e.exec(`CREATE TRIGGER obs_progress_del AFTER DELETE ON progress BEGIN
		SELECT dsv_test_observe_seq((SELECT value FROM sync_state WHERE key = 'progress_seq')); END`)
}

// failWrites makes every insert, update and delete on progress abort.
func (e *progressSeqEnv) failWrites() {
	for _, op := range []string{"INSERT", "UPDATE", "DELETE"} {
		e.exec(`CREATE TRIGGER fail_progress_` + strings.ToLower(op) + ` BEFORE ` + op +
			` ON progress BEGIN SELECT RAISE(ABORT, 'injected write failure'); END`)
	}
}

func (e *progressSeqEnv) committedSeq() int64 {
	e.t.Helper()
	var v int64
	if err := e.reader.QueryRow(`SELECT value FROM sync_state WHERE key = 'progress_seq'`).Scan(&v); err != nil {
		e.t.Fatalf("committed progress_seq: %v", err)
	}
	return v
}

func (e *progressSeqEnv) published() int64 {
	_, p := e.s.getSyncSeqs()
	return p
}

// row returns the committed position and write_seq of item w1 on profile, ok=false if absent.
func (e *progressSeqEnv) row(profile string) (pos, writeSeq int64, ok bool) {
	e.t.Helper()
	err := e.reader.QueryRow(`SELECT position_seconds, write_seq FROM progress WHERE item_id = 'w1' AND profile_id = ?`,
		profile).Scan(&pos, &writeSeq)
	if err == sql.ErrNoRows {
		return 0, 0, false
	}
	if err != nil {
		e.t.Fatalf("read progress row: %v", err)
	}
	return pos, writeSeq, true
}

// assertNothingAheadDuringWrite: at least one observed write, and at every one of them the
// heartbeat and the committed counter still read the starting value.
func (e *progressSeqEnv) assertNothingAheadDuringWrite() {
	e.t.Helper()
	if len(e.obs) == 0 {
		e.t.Fatal("no progress write was observed; the test is not watching the write")
	}
	for _, o := range e.obs {
		if o.published != progressSeqStart {
			e.t.Errorf("heartbeat advertised progressSeq %d while the progress change was uncommitted (start %d): a device syncing then keeps the old position under the new cursor", o.published, progressSeqStart)
		}
		if o.committed != progressSeqStart {
			e.t.Errorf("progress_seq %d was already committed while the progress change was uncommitted (start %d): another writer can commit and publish past it", o.committed, progressSeqStart)
		}
	}
}

// assertAdvancedOnce: after the write, counter and heartbeat both read start+1.
func (e *progressSeqEnv) assertAdvancedOnce() {
	e.t.Helper()
	if c := e.committedSeq(); c != progressSeqStart+1 {
		e.t.Errorf("progress_seq counter %d after one write, want %d", c, progressSeqStart+1)
	}
	if p := e.published(); p != progressSeqStart+1 {
		e.t.Errorf("heartbeat advertises %d after the write committed, want %d: devices never fetch the change", p, progressSeqStart+1)
	}
}

// assertUpsertInOrder: the write was observed with a fresh write_seq, nothing ran ahead of it,
// and the committed row on profile holds pos at that write_seq.
func (e *progressSeqEnv) assertUpsertInOrder(profile string, pos int64) {
	e.t.Helper()
	e.assertNothingAheadDuringWrite()
	for _, o := range e.obs {
		if o.rowSeq != progressSeqStart+1 {
			e.t.Errorf("row written with write_seq %d, want the freshly allocated %d", o.rowSeq, progressSeqStart+1)
		}
	}
	e.assertAdvancedOnce()
	gotPos, gotSeq, ok := e.row(profile)
	if !ok {
		e.t.Fatalf("no committed progress row for w1 on profile %s", profile)
	}
	if gotPos != pos || gotSeq != progressSeqStart+1 {
		e.t.Errorf("committed row pos=%d write_seq=%d, want pos=%d write_seq=%d", gotPos, gotSeq, pos, progressSeqStart+1)
	}
}

// assertNothingAdvanced: a failed write leaves counter and heartbeat at the starting value.
func (e *progressSeqEnv) assertNothingAdvanced() {
	e.t.Helper()
	if p := e.published(); p != progressSeqStart {
		e.t.Errorf("heartbeat advertises %d after a failed write, want %d unchanged", p, progressSeqStart)
	}
	if c := e.committedSeq(); c != progressSeqStart {
		e.t.Errorf("progress_seq counter %d after a failed write, want %d unchanged", c, progressSeqStart)
	}
}

func (e *progressSeqEnv) postProgress(pos int) qaResp {
	e.t.Helper()
	return e.do(qaAlice, "POST", "/items/w1/progress",
		jb(map[string]any{"positionSeconds": pos, "durationSeconds": 3000}), "")
}

// watchStatus sends the DS Video app's WatchStatus update for w1 (WebAPI id 42).
func (e *progressSeqEnv) watchStatus(pos int) webAPIResp {
	e.t.Helper()
	sid := pcSession(e.t, qaAlice)
	m := getOrCreateMapping(sid)
	m.mu.Lock()
	m.movieIDs["42"] = "w1"
	m.mu.Unlock()
	return pcCall(e.t, e.s.handleWebAPIWatchStatus, "update",
		url.Values{"_sid": {sid}, "id": {"42"}, "time": {strconv.Itoa(pos)}, "total_time": {"3000"}})
}

// REST POST /items/{id}/progress, first write for the title (INSERT arm).
func TestProgressSeqOrder_RESTInsert(t *testing.T) {
	e := newProgressSeqEnv(t)
	owner := e.ownerID(qaAlice)
	e.observe()
	r := e.postProgress(1200)
	wantOK(t, r, 200)
	if r.js["applied"] != true {
		t.Errorf("applied = %v, want true: %s", r.js["applied"], r.raw)
	}
	// FR-230/FR-231: no profile header writes to the fallback (owner) profile.
	e.assertUpsertInOrder(owner, 1200)
}

// REST POST over an existing row (ON CONFLICT DO UPDATE arm).
func TestProgressSeqOrder_RESTUpdate(t *testing.T) {
	e := newProgressSeqEnv(t)
	owner := e.ownerID(qaAlice)
	if _, err := e.db.Exec(`INSERT INTO progress(item_id, user_id, profile_id, position_seconds, duration_seconds, updated_at, write_seq)
		VALUES('w1', ?, ?, 300, 3000, '2026-10-01T00:00:00Z', 3)`, qaAlice.id, owner); err != nil {
		t.Fatalf("seed progress: %v", err)
	}
	e.observe()
	r := e.postProgress(2400)
	wantOK(t, r, 200)
	e.assertUpsertInOrder(owner, 2400)
}

// A REST write that fails leaves nothing advertised or allocated, and answers 500 so the
// client's outbox retries.
func TestProgressSeqOrder_RESTFailure(t *testing.T) {
	e := newProgressSeqEnv(t)
	owner := e.ownerID(qaAlice)
	e.failWrites()
	r := e.postProgress(1200)
	wantErr(t, r, 500, "db_error")
	e.assertNothingAdvanced()
	if _, _, ok := e.row(owner); ok {
		t.Error("a failed write left a progress row behind")
	}
}

// SYNO.VideoStation2.WatchStatus update, the DS Video app's progress write.
func TestProgressSeqOrder_WebAPIWatchStatus(t *testing.T) {
	e := newProgressSeqEnv(t)
	owner := e.ownerID(qaAlice)
	e.observe()
	r := e.watchStatus(777)
	if !r.Success {
		t.Fatalf("WatchStatus update failed: code %d", r.Error.Code)
	}
	e.assertUpsertInOrder(owner, 777)
}

func TestProgressSeqOrder_WebAPIWatchStatusFailure(t *testing.T) {
	e := newProgressSeqEnv(t)
	owner := e.ownerID(qaAlice)
	e.failWrites()
	r := e.watchStatus(777)
	if r.Success || r.Error.Code != 100 {
		t.Errorf("failed WatchStatus write answered success=%v code=%d, want error 100", r.Success, r.Error.Code)
	}
	e.assertNothingAdvanced()
	if _, _, ok := e.row(owner); ok {
		t.Error("a failed write left a progress row behind")
	}
}

// The periodic orphan purge deletes progress rows; devices learn of it through progress_seq,
// which must not be visible before the deletion is.
func TestProgressSeqOrder_OrphanPurge(t *testing.T) {
	e := newProgressSeqEnv(t)
	insertProgress(t, e.s, "goneA", "pr1")
	insertProgress(t, e.s, "goneB", "pr1")
	e.observe()
	n, err := e.s.purgeOrphanedProgress(time.Now())
	if err != nil || n != 2 {
		t.Fatalf("purge = %d, %v; want 2, nil", n, err)
	}
	e.assertNothingAheadDuringWrite()
	e.assertAdvancedOnce()
	var left int
	if err := e.reader.QueryRow(`SELECT COUNT(*) FROM progress WHERE item_id IN ('goneA','goneB')`).Scan(&left); err != nil {
		t.Fatal(err)
	}
	if left != 0 {
		t.Errorf("%d orphan rows still committed after the purge reported done", left)
	}
}

// A purge with nothing to remove does not move the counter (no needless device refetch).
func TestProgressSeqOrder_OrphanPurgeNothingToDo(t *testing.T) {
	e := newProgressSeqEnv(t)
	n, err := e.s.purgeOrphanedProgress(time.Now())
	if err != nil || n != 0 {
		t.Fatalf("purge = %d, %v; want 0, nil", n, err)
	}
	e.assertNothingAdvanced()
}

func TestProgressSeqOrder_OrphanPurgeFailure(t *testing.T) {
	e := newProgressSeqEnv(t)
	insertProgress(t, e.s, "goneA", "pr1")
	e.failWrites()
	if _, err := e.s.purgeOrphanedProgress(time.Now()); err == nil {
		t.Fatal("purge reported success through an injected delete failure")
	}
	e.assertNothingAdvanced()
}

// The purge and the progress_seq bump that tells devices about it commit together: if the
// bump fails, the rows stay. A purge committed without its bump leaves every device showing
// the removed positions, with nothing ever prompting a refetch.
func TestProgressSeqOrder_OrphanPurgeBumpFailureKeepsRows(t *testing.T) {
	e := newProgressSeqEnv(t)
	insertProgress(t, e.s, "goneA", "pr1")
	e.exec(`CREATE TRIGGER fail_progress_seq BEFORE UPDATE ON sync_state WHEN OLD.key = 'progress_seq'
		BEGIN SELECT RAISE(ABORT, 'injected counter failure'); END`)
	if _, err := e.s.purgeOrphanedProgress(time.Now()); err == nil {
		t.Fatal("purge reported success although its progress_seq bump failed")
	}
	e.assertNothingAdvanced()
	if !progressExists(t, e.s, "goneA", "pr1") {
		t.Error("the purge committed its deletion without the progress_seq bump: devices are never told")
	}
}

// Publishing never lowers the advertised progressSeq: writers commit concurrently, and the
// slower of two can publish last.
func TestProgressSeqPublishNeverLowers(t *testing.T) {
	e := newProgressSeqEnv(t)
	e.s.publishProgressSeq(progressSeqStart + 5)
	e.s.publishProgressSeq(progressSeqStart + 2)
	if p := e.published(); p != progressSeqStart+5 {
		t.Errorf("heartbeat advertises %d after publishing %d then %d, want %d", p, progressSeqStart+5, progressSeqStart+2, progressSeqStart+5)
	}
}

// failAtCommit makes the transaction that writes or deletes a progress row fail at COMMIT,
// after every statement in it succeeded: each progress write also inserts a row whose
// DEFERRABLE INITIALLY DEFERRED foreign key is violated, which SQLite checks only at
// commit. The server is moved onto a second pool over the same file with foreign_keys on
// (the test server runs without it). This is the only observation point for a publish
// placed between the last write and the commit: the triggers above fire before it.
//
// SQLite leaves the transaction open after a failed deferred-FK COMMIT, so the server pool
// is unusable for writes afterwards; assertions go through e.reader and the atomics.
func (e *progressSeqEnv) failAtCommit() {
	e.t.Helper()
	e.exec(`CREATE TABLE commit_gate_parent(id INTEGER PRIMARY KEY)`)
	e.exec(`CREATE TABLE commit_gate(ref INTEGER REFERENCES commit_gate_parent(id) DEFERRABLE INITIALLY DEFERRED)`)
	for _, op := range []string{"INSERT", "UPDATE", "DELETE"} {
		e.exec(`CREATE TRIGGER commit_gate_` + strings.ToLower(op) + ` AFTER ` + op +
			` ON progress BEGIN INSERT INTO commit_gate(ref) VALUES (999); END`)
	}
	fk, err := sql.Open("sqlite", e.dbPath+"?_pragma=busy_timeout(30000)&_pragma=journal_mode(WAL)&_pragma=foreign_keys(1)")
	if err != nil {
		e.t.Fatalf("open foreign-key pool: %v", err)
	}
	e.t.Cleanup(func() { fk.Close() })
	e.s.db = fk
}

func TestProgressSeqOrder_RESTCommitFailure(t *testing.T) {
	e := newProgressSeqEnv(t)
	owner := e.ownerID(qaAlice)
	e.failAtCommit()
	r := e.postProgress(1200)
	wantErr(t, r, 500, "db_error")
	e.assertNothingAdvanced()
	if _, _, ok := e.row(owner); ok {
		t.Error("a write whose commit failed is visible to another connection")
	}
}

func TestProgressSeqOrder_WebAPIWatchStatusCommitFailure(t *testing.T) {
	e := newProgressSeqEnv(t)
	owner := e.ownerID(qaAlice)
	e.failAtCommit()
	r := e.watchStatus(777)
	if r.Success || r.Error.Code != 100 {
		t.Errorf("WatchStatus write whose commit failed answered success=%v code=%d, want error 100", r.Success, r.Error.Code)
	}
	e.assertNothingAdvanced()
	if _, _, ok := e.row(owner); ok {
		t.Error("a write whose commit failed is visible to another connection")
	}
}

func TestProgressSeqOrder_OrphanPurgeCommitFailure(t *testing.T) {
	e := newProgressSeqEnv(t)
	insertProgress(t, e.s, "goneA", "pr1")
	e.failAtCommit()
	if _, err := e.s.purgeOrphanedProgress(time.Now()); err == nil {
		t.Fatal("purge reported success although its commit failed")
	}
	e.assertNothingAdvanced()
	var left int
	if err := e.reader.QueryRow(`SELECT COUNT(*) FROM progress WHERE item_id = 'goneA'`).Scan(&left); err != nil {
		t.Fatal(err)
	}
	if left != 1 {
		t.Error("a purge whose commit failed is visible to another connection")
	}
}
