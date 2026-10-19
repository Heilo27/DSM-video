package main

// TASK-1065, FRD-002 FR-245 / AC-002-70 (with FR-244): the delta feed (GET /sync/items) must deliver every row
// that changed, whatever page size the client asks for. Observed on a real library: a client
// that synced in pages of 200 held 25 rows at their OLD change_seq and age level because the
// server's cursor skipped one row at every page boundary (5,432 rows, 28 pages, 27 rows
// missing; 16 missing at 333, 10 at 500, 5 at 1000). A row re-rated upward and dropped this
// way stays at its old, lower level on the device, which is the one case where a restricted
// profile is shown a title it should not see.

import (
	"fmt"
	"sort"
	"testing"
)

// seedSeqs seeds one item per entry of seqs (ids "i0", "i1", ...) with that change_seq and
// sets the published item_seq to the highest one: a library a fresh device has not synced.
func (e *qaEnv) seedSeqs(seqs []int) []string {
	e.t.Helper()
	ids := make([]string, len(seqs))
	top := 0
	for i, seq := range seqs {
		ids[i] = fmt.Sprintf("i%d", i)
		e.seedItem(ids[i], "", sp("TV-14"))
		if _, err := e.db.Exec(`UPDATE items SET change_seq=? WHERE id=?`, seq, ids[i]); err != nil {
			e.t.Fatal(err)
		}
		if seq > top {
			top = seq
		}
	}
	if _, err := e.db.Exec(`UPDATE sync_state SET value=? WHERE key='item_seq'`, top); err != nil {
		e.t.Fatal(err)
	}
	return ids
}

// crawlSync follows the cursor exactly as the client's runDeltaSync does: the next request
// carries the response's nextSeq as `since`, and nextAfterRowid as afterRowid only when the
// server supplied one. It returns every id delivered and fails if the walk does not end.
func (e *qaEnv) crawlSync(owner string, limit int) map[string]bool {
	e.t.Helper()
	return e.crawlSyncFrom(owner, 0, limit)
}

// crawlSyncFrom is crawlSync for a device whose stored cursor is since.
func (e *qaEnv) crawlSyncFrom(owner string, since int64, limit int) map[string]bool {
	e.t.Helper()
	after := int64(0)
	seen := map[string]bool{}
	for page := 0; page < 200; page++ {
		path := fmt.Sprintf("/sync/items?since=%d&limit=%d", since, limit)
		if after > 0 {
			path += fmt.Sprintf("&afterRowid=%d", after)
		}
		r := e.do(qaAlice, "GET", path, "", owner)
		if r.code != 200 {
			e.t.Fatalf("GET %s = %d %s", path, r.code, r.raw)
		}
		for id := range idsOf(e.t, r, "items") {
			seen[id] = true
		}
		if more, _ := r.js["hasMore"].(bool); !more {
			return seen
		}
		since = int64(r.num("nextSeq"))
		after = int64(r.num("nextAfterRowid"))
	}
	e.t.Fatalf("limit %d: the cursor never reached the end of the feed (stalled or looping)", limit)
	return nil
}

func (e *qaEnv) assertCrawlComplete(owner string, ids []string, limit int) {
	e.t.Helper()
	seen := e.crawlSync(owner, limit)
	var missing []string
	for _, id := range ids {
		if !seen[id] {
			missing = append(missing, id)
		}
	}
	sort.Strings(missing)
	if len(missing) > 0 {
		e.t.Errorf("limit %d: %d of %d rows never delivered: %v", limit, len(missing), len(ids), missing)
	}
}

// Every row has its own change_seq (the live library's shape): a crawl at any page size
// delivers all of them.
// Red if the cursor is taken from the look-ahead row that is not on the page (one row lost
// per page boundary).
func TestSyncItemsPaging_DistinctSeqsLoseNoRowAtAnyPageSize(t *testing.T) {
	e := newQAEnv(t)
	owner := e.setOwnerPin(qaAlice, "0420")
	ids := e.seedSeqs([]int{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11})
	for _, limit := range []int{1, 2, 3, 4, 5, 10, 11, 12} {
		e.assertCrawlComplete(owner, ids, limit)
	}
}

// Rows sharing one change_seq (a ladder reconcile bumps every moved title to one new value,
// FR-244) can straddle a page boundary, including a run longer than a page.
// Red if rows that share the boundary's seq are skipped, or if a run longer than the page
// makes the cursor stall.
func TestSyncItemsPaging_RowsSharingASeqAreNotSplitAcrossPages(t *testing.T) {
	cases := map[string][]int{
		"one shared seq longer than a page": {9, 9, 9, 9, 9, 9, 9},
		"shared run straddling a boundary":  {1, 2, 2, 2, 2, 3, 4},
		"shared run at the very start":      {1, 1, 1, 2, 3, 4, 5},
		"shared run at the very end":        {1, 2, 3, 4, 8, 8, 8},
	}
	for name, seqs := range cases {
		t.Run(name, func(t *testing.T) {
			e := newQAEnv(t)
			owner := e.setOwnerPin(qaAlice, "0420")
			ids := e.seedSeqs(seqs)
			// One env per case, crawled at several page sizes (the feed is read-only).
			for _, limit := range []int{1, 2, 3, 4} {
				e.assertCrawlComplete(owner, ids, limit)
			}
		})
	}
}

// A delta from a cursor never re-sends rows at or below it and still ends on the highest seq,
// so the FR-244 contract (OC-2135) is unchanged for a page that holds the whole delta.
func TestSyncItemsPaging_SinglePageDeltaReportsTopSeq(t *testing.T) {
	e := newQAEnv(t)
	owner := e.setOwnerPin(qaAlice, "0420")
	e.seedSeqs([]int{1, 2, 3, 4, 5})
	r := e.do(qaAlice, "GET", "/sync/items?since=3&limit=500", "", owner)
	if r.code != 200 {
		t.Fatalf("delta = %d %s", r.code, r.raw)
	}
	if got := len(idsOf(t, r, "items")); got != 2 {
		t.Errorf("delta since 3 returned %d rows, want 2 (seq 4 and 5)", got)
	}
	if r.num("nextSeq") != 5 {
		t.Errorf("nextSeq = %d, want 5", r.num("nextSeq"))
	}
}
