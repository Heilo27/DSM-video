package main

// TASK-1068 x TASK-1067: the FR-246 heal and the FR-241a recompute on the same first start.

import (
	"context"
	"fmt"
	"reflect"
	"testing"

	"dsvideo/backend/internal/rating"
)

// The server runs the heal and then the ladder reconcile (main.go); each keeps its own record
// (sync_heals.name, rating_ladder_state), so each runs once. A device at its old cursor 8 must
// end holding every title, the moved ones at ageLevel 3, and a second start must change no
// change_seq and not advance item_seq. Both orders are covered: the migrations are
// independent, so neither order may lose the new levels.
// Red if one migration's record suppresses the other, if the reconcile re-sends untouched
// rows, or if a second start moves any sequence.
func TestFR241a_HealAndRecomputeOnTheSameFirstStart(t *testing.T) {
	for _, order := range []string{"heal then reconcile", "reconcile then heal"} {
		t.Run(order, func(t *testing.T) {
			e := eraEnv(t)
			owner := e.setOwnerPin(qaAlice, "0420")
			ctx := context.Background()

			start := func() {
				if order == "reconcile then heal" {
					e.s.startupReconcileRatingLadder(ctx)
					e.s.startupHealStaleItemCursors(ctx)
				} else {
					e.s.startupHealStaleItemCursors(ctx)
					e.s.startupReconcileRatingLadder(ctx)
				}
			}
			start()

			wantAll := map[string]float64{"jaws84": 3, "raid81": 3, "grease78": 3, "pg85": 2, "pgnone": 2, "pg13_84": 3, "g50": 1, "tvpg": 2}
			final := e.storedItemSeq()
			// Eight heal values (9..16) plus one value for the three moved titles (17).
			if final != 17 {
				t.Errorf("item_seq after first start = %d, want 17", final)
			}
			if published, _ := e.s.getSyncSeqs(); published != final {
				t.Errorf("published item_seq = %d, want %d", published, final)
			}

			// The stale device (cursor 8) walks the feed: every title once, with the new levels.
			got := map[string]float64{}
			since, after := int64(8), int64(0)
			for page := 0; page < 20; page++ {
				// As the client's runDeltaSync does (FR-245): nextSeq as since, and nextAfterRowid as
				// afterRowid only when the server supplied one.
				path := fmt.Sprintf("/sync/items?since=%d&limit=3", since)
				if after > 0 {
					path += fmt.Sprintf("&afterRowid=%d", after)
				}
				r := e.do(qaAlice, "GET", path, "", owner)
				wantOK(t, r, 200)
				for _, it := range r.js["items"].([]any) {
					m := it.(map[string]any)
					got[m["id"].(string)], _ = m["ageLevel"].(float64)
				}
				if more, _ := r.js["hasMore"].(bool); !more {
					break
				}
				since, after = int64(r.num("nextSeq")), int64(r.num("nextAfterRowid"))
			}
			if !reflect.DeepEqual(got, wantAll) {
				t.Errorf("stale device ended with %v, want %v", got, wantAll)
			}

			if n := e.count(`SELECT COUNT(*) FROM sync_heals WHERE name = ?`, syncHealPageSkip); n != 1 {
				t.Errorf("heal marker rows = %d, want 1", n)
			}
			if got, want := e.storedLadderFingerprint(), rating.CurrentLevels().Fingerprint(); got != want {
				t.Errorf("ladder fingerprint = %s, want live %s", got, want)
			}

			// Second start: neither migration runs again.
			seqs := e.changeSeqs()
			start()
			if after := e.changeSeqs(); !reflect.DeepEqual(after, seqs) {
				t.Errorf("second start moved change_seq: %v -> %v", seqs, after)
			}
			if got := e.storedItemSeq(); got != final {
				t.Errorf("second start moved item_seq %d -> %d", final, got)
			}
			if n := e.count(`SELECT COUNT(*) FROM sync_heals WHERE name = ?`, syncHealPageSkip); n != 1 {
				t.Errorf("heal marker rows after second start = %d, want 1", n)
			}

			// In main's order, a device that already took the heal (cursor at the heal's end, 16)
			// still receives the moved titles: the reconcile stamps them above the heal's range.
			if order == "heal then reconcile" {
				r := e.do(qaAlice, "GET", "/sync/items?since=16&limit=100", "", owner)
				wantOK(t, r, 200)
				seen := map[string]float64{}
				for _, it := range r.js["items"].([]any) {
					m := it.(map[string]any)
					seen[m["id"].(string)], _ = m["ageLevel"].(float64)
				}
				if want := map[string]float64{"jaws84": 3, "raid81": 3, "grease78": 3}; !reflect.DeepEqual(seen, want) {
					t.Errorf("delta above the heal range = %v, want %v", seen, want)
				}
			}
		})
	}
}
