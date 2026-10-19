package main

// TASK-1067, FRD-002 FR-246 / AC-002-71: a device left stale by the pre-FR-245 page-boundary
// skip converges after the server upgrade, once, without touching user data.
//
// The stale device is modelled exactly as it is on a phone: its cursor equals the server's
// item_seq, so "change_seq > cursor" returns nothing, and it is missing rows the server
// holds. The tests drive healStaleItemCursors (the code main() runs through
// startupHealStaleItemCursors) against a real migrated database and the real /sync routes.

import (
	"context"
	"database/sql"
	"fmt"
	"sort"
	"strings"
	"testing"
	"time"
)

// seqRange returns n distinct change_seqs 1..n, a library whose every row has its own value.
func seqRange(n int) []int {
	seqs := make([]int, n)
	for i := range seqs {
		seqs[i] = i + 1
	}
	return seqs
}

func (e *qaEnv) heal(batch int) syncHealResult {
	e.t.Helper()
	res, err := healStaleItemCursors(context.Background(), e.db, syncHealPageSkip, batch)
	if err != nil {
		e.t.Fatalf("heal: %v", err)
	}
	return res
}

// legacyWalk follows the feed the way a client that predates afterRowid does: only nextSeq
// moves the cursor. It fails if the walk does not end.
func (e *qaEnv) legacyWalk(owner string, since int64, limit int) map[string]bool {
	e.t.Helper()
	seen := map[string]bool{}
	for page := 0; page < 400; page++ {
		r := e.do(qaAlice, "GET", fmt.Sprintf("/sync/items?since=%d&limit=%d", since, limit), "", owner)
		if r.code != 200 {
			e.t.Fatalf("legacy walk = %d %s", r.code, r.raw)
		}
		for id := range idsOf(e.t, r, "items") {
			seen[id] = true
		}
		if more, _ := r.js["hasMore"].(bool); !more {
			return seen
		}
		next := int64(r.num("nextSeq"))
		if next <= since {
			e.t.Fatalf("legacy walk stalled at since=%d (nextSeq=%d)", since, next)
		}
		since = next
	}
	e.t.Fatal("legacy walk never ended")
	return nil
}

func (e *qaEnv) assertAll(what string, seen map[string]bool, ids []string) {
	e.t.Helper()
	var missing []string
	for _, id := range ids {
		if !seen[id] {
			missing = append(missing, id)
		}
	}
	sort.Strings(missing)
	if len(missing) > 0 {
		e.t.Errorf("%s: %d of %d rows never delivered: %v", what, len(missing), len(ids), missing)
	}
}

// A device whose cursor already equals item_seq gets nothing before the heal (the bug this
// task exists for) and every row after it, at any page size, with or without afterRowid.
// Devices at older cursors get every row too. The startup wrapper publishes the new
// counter, which is what /sync/status advertises and the device compares to its cursor.
// Red without the heal: the stale device is told there is nothing to fetch.
func TestSyncHeal_StaleDeviceAtOldItemSeqReceivesEveryRow(t *testing.T) {
	e := newQAEnv(t)
	owner := e.setOwnerPin(qaAlice, "0420")
	ids := e.seedSeqs(seqRange(57))
	stale := e.storedItemSeq()

	if got := e.crawlSyncFrom(owner, stale, 10); len(got) != 0 {
		t.Fatalf("premise: before the heal a device at item_seq %d should be told nothing changed, got %d rows", stale, len(got))
	}

	e.s.startupHealStaleItemCursors(context.Background())

	status := e.do(qaAlice, "GET", "/sync/status", "", owner)
	if status.code != 200 {
		t.Fatalf("/sync/status = %d %s", status.code, status.raw)
	}
	if got := int64(status.num("itemSeq")); got <= stale {
		t.Fatalf("/sync/status itemSeq = %d, want above the stale cursor %d so the device sees it is behind", got, stale)
	}
	for _, cursor := range []int64{stale, stale - 20, 0} {
		for _, limit := range []int{1, 7, 500} {
			e.assertAll(fmt.Sprintf("cursor %d limit %d", cursor, limit), e.crawlSyncFrom(owner, cursor, limit), ids)
		}
	}
	e.assertAll("legacy client (no afterRowid) at the stale cursor", e.legacyWalk(owner, stale, 7), ids)
}

// The pass records itself: a second startup changes nothing, even after the library has
// moved on, and a row written after the heal keeps its own sequence.
// Red if the marker is not honoured: the second pass would re-stamp every row and bump
// item_seq by the item count on every start.
func TestSyncHeal_SecondStartupDoesNotRerun(t *testing.T) {
	e := newQAEnv(t)
	e.seedSeqs(seqRange(23))
	first := e.heal(5)
	if !first.Ran || first.Rows != 23 {
		t.Fatalf("first pass = %+v, want Ran with 23 rows", first)
	}

	// The library moves on: a scan writes a new row at the next sequence.
	e.seedItem("later", "", sp("G"))
	var seq int64
	if _, err := e.s.writeWithItemSeq(context.Background(), func(tx *sql.Tx, s int64) error {
		seq = s
		_, err := tx.Exec(`UPDATE items SET change_seq=? WHERE id='later'`, s)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	before := e.changeSeqs()
	seqBefore := e.storedItemSeq()

	second := e.heal(5)
	if second.Ran || second.Rows != 0 || second.Batches != 0 {
		t.Errorf("second pass = %+v, want a no-op", second)
	}
	e.s.startupHealStaleItemCursors(context.Background()) // main()'s path, a third time
	if after := e.changeSeqs(); fmt.Sprint(after) != fmt.Sprint(before) {
		t.Errorf("change_seq values moved on a later start:\n before %v\n after  %v", before, after)
	}
	if got := e.storedItemSeq(); got != seqBefore {
		t.Errorf("item_seq = %d after later starts, want %d", got, seqBefore)
	}
	if before["later"] != seq {
		t.Errorf("row written after the heal has change_seq %d, want %d", before["later"], seq)
	}
	var n int
	if err := e.db.QueryRow(`SELECT COUNT(*) FROM sync_heals WHERE name=?`, syncHealPageSkip).Scan(&n); err != nil || n != 1 {
		t.Errorf("sync_heals rows for the heal = %d (err %v), want exactly 1", n, err)
	}
}

// dumpExcept renders every row of every table, as text, skipping the named tables.
func (e *qaEnv) dumpExcept(skip map[string]bool) []string {
	e.t.Helper()
	names, err := e.db.Query(`SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name`)
	if err != nil {
		e.t.Fatal(err)
	}
	var tables []string
	for names.Next() {
		var n string
		if err := names.Scan(&n); err != nil {
			e.t.Fatal(err)
		}
		if !skip[n] {
			tables = append(tables, n)
		}
	}
	names.Close()
	var out []string
	for _, tbl := range tables {
		out = append(out, e.dumpTable(tbl, "")...)
	}
	return out
}

// dumpTable renders a table's rows, leaving out the column named omit.
func (e *qaEnv) dumpTable(tbl, omit string) []string {
	e.t.Helper()
	cols, err := e.db.Query(fmt.Sprintf(`PRAGMA table_info(%q)`, tbl))
	if err != nil {
		e.t.Fatal(err)
	}
	var names []string
	for cols.Next() {
		var cid, notnull, pk int
		var name, typ string
		var dflt sql.NullString
		if err := cols.Scan(&cid, &name, &typ, &notnull, &dflt, &pk); err != nil {
			e.t.Fatal(err)
		}
		if name != omit {
			names = append(names, name)
		}
	}
	cols.Close()
	rows, err := e.db.Query(fmt.Sprintf(`SELECT %s FROM %q`, strings.Join(names, ","), tbl))
	if err != nil {
		e.t.Fatal(err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		vals := make([]any, len(names))
		ptrs := make([]any, len(names))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			e.t.Fatal(err)
		}
		out = append(out, fmt.Sprintf("%s|%v", tbl, vals))
	}
	sort.Strings(out)
	return out
}

// Non-destructive: progress, watchlist, profiles and every other table are byte-identical
// after the heal, and items differ only in change_seq. deleted_items is untouched too, so a
// deletion is neither lost nor replayed.
// Red if the heal rewrote, dropped or re-created anything but change_seq and item_seq.
func TestSyncHeal_TouchesOnlyChangeSeqAndTheCounter(t *testing.T) {
	e := newQAEnv(t)
	e.setOwnerPin(qaAlice, "0420")
	e.seedSeqs(seqRange(31))
	mustExec := func(q string, args ...any) {
		t.Helper()
		if _, err := e.db.Exec(q, args...); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	mustExec(`INSERT INTO progress(item_id, user_id, profile_id, position_seconds, duration_seconds, updated_at) VALUES ('i3', ?, ?, 120, 5400, '2026-10-01T00:00:00Z')`, qaAlice.id, e.ownerID(qaAlice))
	mustExec(`INSERT INTO watchlist(item_id, user_id, profile_id) VALUES ('i4', ?, ?)`, qaAlice.id, e.ownerID(qaAlice))
	mustExec(`INSERT INTO deleted_items(item_id, change_seq, deleted_at) VALUES ('gone', 12, '2026-10-01T00:00:00Z')`)

	skip := map[string]bool{"items": true, "sync_state": true, "sync_heals": true}
	otherBefore := e.dumpExcept(skip)
	itemsBefore := e.dumpTable("items", "change_seq")
	if len(otherBefore) == 0 {
		t.Fatal("premise: no user data seeded")
	}

	e.heal(4)

	if after := e.dumpExcept(skip); fmt.Sprint(after) != fmt.Sprint(otherBefore) {
		t.Errorf("user data changed by the heal:\n before %v\n after  %v", otherBefore, after)
	}
	if after := e.dumpTable("items", "change_seq"); fmt.Sprint(after) != fmt.Sprint(itemsBefore) {
		t.Errorf("an items column other than change_seq changed")
	}
	// Every row got its own value above the old counter, and the counter is the highest.
	seen := map[int64]bool{}
	var top int64
	for id, seq := range e.changeSeqs() {
		if seq <= 31 {
			t.Errorf("%s kept change_seq %d, at or below the old item_seq 31", id, seq)
		}
		if seen[seq] {
			t.Errorf("change_seq %d assigned twice", seq)
		}
		seen[seq] = true
		if seq > top {
			top = seq
		}
	}
	if got := e.storedItemSeq(); got != top || got != 31+31 {
		t.Errorf("item_seq = %d, highest change_seq = %d, want both 62", got, top)
	}
}

// An empty library has no stale device and nothing to stamp. The marker is still recorded,
// so items scanned later are not re-stamped by the next start.
func TestSyncHeal_EmptyLibraryRecordsMarkerAndStampsNothingLater(t *testing.T) {
	e := newQAEnv(t)
	if res := e.heal(5); res.Ran || res.Rows != 0 {
		t.Fatalf("empty library: %+v, want nothing stamped", res)
	}
	e.seedSeqs([]int{40, 41, 42})
	if res := e.heal(5); res.Ran {
		t.Fatalf("second start after items arrived re-ran the heal: %+v", res)
	}
	if got := e.changeSeqs(); got["i0"] != 40 || got["i1"] != 41 || got["i2"] != 42 {
		t.Errorf("later items were re-stamped: %v", got)
	}
}

// An error between batches leaves earlier batches committed, the counter and marker
// untouched, and the next start finishes the job from the same base: every row distinct,
// above the old counter, and the counter on the highest.
// Red if the counter or marker are committed before the last batch (a stale device would be
// told it is current while rows still carry old values), or if the retry cannot converge.
func TestSyncHeal_FailureMidwayIsRetriedAndConverges(t *testing.T) {
	e := newQAEnv(t)
	owner := e.setOwnerPin(qaAlice, "0420")
	ids := e.seedSeqs(seqRange(40))
	if _, err := e.db.Exec(`CREATE TRIGGER heal_boom BEFORE UPDATE OF change_seq ON items WHEN NEW.id='i30'
		BEGIN SELECT RAISE(ABORT, 'boom'); END`); err != nil {
		t.Fatal(err)
	}
	if _, err := healStaleItemCursors(context.Background(), e.db, syncHealPageSkip, 8); err == nil {
		t.Fatal("heal with a failing row returned no error")
	}
	if got := e.storedItemSeq(); got != 40 {
		t.Errorf("item_seq = %d after a failed heal, want it untouched at 40", got)
	}
	var marked int
	if err := e.db.QueryRow(`SELECT COUNT(*) FROM sync_heals`).Scan(&marked); err != nil || marked != 0 {
		t.Errorf("marker rows after a failed heal = %d (err %v), want 0", marked, err)
	}

	if _, err := e.db.Exec(`DROP TRIGGER heal_boom`); err != nil {
		t.Fatal(err)
	}
	res := e.heal(8)
	if !res.Ran || res.Rows != 40 || res.FromSeq != 40 || res.ToSeq != 80 {
		t.Fatalf("retry = %+v, want 40 rows, item_seq 40 -> 80", res)
	}
	seen := map[int64]bool{}
	for id, seq := range e.changeSeqs() {
		if seq <= 40 || seq > 80 || seen[seq] {
			t.Errorf("%s change_seq %d: want distinct values in 41..80", id, seq)
		}
		seen[seq] = true
	}
	e.assertAll("stale device after the retry", e.crawlSyncFrom(owner, 40, 9), ids)
}

// The cost on NAS-class data: ~6,000 rows on an on-disk WAL database with the production
// pragmas. Logs the runtime; asserts the pass is batched (no single transaction over the
// whole library) and finishes well inside any plausible startup budget.
func TestSyncHeal_SixThousandRowsIsBatchedAndFast(t *testing.T) {
	e := newQAEnv(t)
	const n = 6000
	tx, err := e.db.Begin()
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < n; i++ {
		if _, err := tx.Exec(`INSERT INTO items(id, library_id, type, title, path, added_at, updated_at, change_seq)
			VALUES (?, 'lib1', 'movie', ?, ?, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', ?)`,
			fmt.Sprintf("m%d", i), "t", fmt.Sprintf("/media/%d.mkv", i), i+1); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := tx.Exec(`UPDATE sync_state SET value=? WHERE key='item_seq'`, n); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}

	start := time.Now()
	res := e.heal(syncHealBatch)
	elapsed := time.Since(start)
	t.Logf("healed %d rows in %d batches in %s (item_seq %d -> %d)", res.Rows, res.Batches, elapsed, res.FromSeq, res.ToSeq)
	if res.Rows != n || res.Batches != n/syncHealBatch || res.ToSeq != 2*n {
		t.Errorf("result %+v, want %d rows in %d batches, item_seq to %d", res, n, n/syncHealBatch, 2*n)
	}
	if elapsed > 30*time.Second {
		t.Errorf("heal took %s on 6,000 rows", elapsed)
	}
}
