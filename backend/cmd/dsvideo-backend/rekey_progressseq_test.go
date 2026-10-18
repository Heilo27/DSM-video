package main

// TASK-941: when a different-path conversion re-keys a title (updateCodecInfoRepath ->
// normalize.RekeyAndMigrateTx), its progress rows move from the old id to the new one.
// Devices refetch /progress/all only when the heartbeat's progressSeq moves, so a re-key
// that moves or prunes progress must allocate a progress_seq INSIDE the re-key transaction
// and publish it only after that transaction commits. Without the bump every device kept
// the position under the vanished old id until some unrelated progress write.
//
// Observation point: a trigger on sync_state that fires at the instant progress_seq is
// allocated. At that instant a second connection must still see the progress row under the
// OLD id (the move is uncommitted, so the allocation is in the same transaction as the
// move) and the heartbeat must still advertise the starting value.

import (
	"testing"
)

// rekeyAllocObservation is what the progress_seq allocation trigger saw.
type rekeyAllocObservation struct {
	allocated, published int64
	underOld, underNewID int
}

// observeProgressSeqAlloc fires on every progress_seq allocation and records, through the
// second connection, where the progress row for oldID/newID is committed at that instant.
func (e *progressSeqEnv) observeProgressSeqAlloc(oldID, newID string) *[]rekeyAllocObservation {
	e.t.Helper()
	var obs []rekeyAllocObservation
	seqObserver.mu.Lock()
	seqObserver.fn = func(allocated int64) {
		o := rekeyAllocObservation{allocated: allocated}
		_, o.published = e.s.getSyncSeqs()
		if err := e.reader.QueryRow(`SELECT COUNT(*) FROM progress WHERE item_id = ?`, oldID).Scan(&o.underOld); err != nil {
			e.t.Errorf("reader: %v", err)
		}
		if err := e.reader.QueryRow(`SELECT COUNT(*) FROM progress WHERE item_id = ?`, newID).Scan(&o.underNewID); err != nil {
			e.t.Errorf("reader: %v", err)
		}
		obs = append(obs, o)
	}
	seqObserver.mu.Unlock()
	e.exec(`CREATE TRIGGER obs_progress_seq_alloc AFTER UPDATE ON sync_state WHEN NEW.key = 'progress_seq'
		BEGIN SELECT dsv_test_observe_seq(NEW.value); END`)
	return &obs
}

func (e *progressSeqEnv) committedProgressRows(itemID string) int {
	e.t.Helper()
	var n int
	if err := e.reader.QueryRow(`SELECT COUNT(*) FROM progress WHERE item_id = ?`, itemID).Scan(&n); err != nil {
		e.t.Fatalf("count progress for %s: %v", itemID, err)
	}
	return n
}

// A re-key that moves a progress row bumps progress_seq once, in the re-key transaction,
// and publishes it after commit; the row is committed under the new id.
func TestProgressSeqOrder_RekeyMovesProgress(t *testing.T) {
	e := newProgressSeqEnv(t)
	insertProgress(t, e.s, "w1", "pr1")
	newPath := "/media/w1.mp4"
	newID := itemIDFromPath(newPath)
	obs := e.observeProgressSeqAlloc("w1", newID)

	e.s.updateCodecInfoRepath("w1", newPath, seqOrderProbe())

	if len(*obs) != 1 {
		t.Fatalf("progress_seq allocated %d times during a re-key that moved one progress row, want 1: devices never refetch the moved position", len(*obs))
	}
	o := (*obs)[0]
	if o.allocated != progressSeqStart+1 {
		t.Errorf("allocated progress_seq %d, want %d", o.allocated, progressSeqStart+1)
	}
	if o.underOld != 1 || o.underNewID != 0 {
		t.Errorf("at allocation another connection saw the progress row under old=%d new=%d, want old=1 new=0: the bump is not in the re-key transaction", o.underOld, o.underNewID)
	}
	if o.published != progressSeqStart {
		t.Errorf("heartbeat advertised %d while the re-key was uncommitted, want %d", o.published, progressSeqStart)
	}
	e.assertAdvancedOnce()
	if old, moved := e.committedProgressRows("w1"), e.committedProgressRows(newID); old != 0 || moved != 1 {
		t.Errorf("after the re-key progress rows: old id %d, new id %d; want 0, 1", old, moved)
	}
}

// A re-key with no progress for the title does not move the counter (no needless refetch).
func TestProgressSeqOrder_RekeyWithoutProgress(t *testing.T) {
	e := newProgressSeqEnv(t)
	newPath := "/media/w1.mp4"
	newID := itemIDFromPath(newPath)
	obs := e.observeProgressSeqAlloc("w1", newID)

	e.s.updateCodecInfoRepath("w1", newPath, seqOrderProbe())

	var n int
	if err := e.reader.QueryRow(`SELECT COUNT(*) FROM items WHERE id = ?`, newID).Scan(&n); err != nil || n != 1 {
		t.Fatalf("item not re-keyed to %s (count %d, err %v): the test is not exercising the re-key", newID, n, err)
	}
	if len(*obs) != 0 {
		t.Errorf("progress_seq allocated %d times by a re-key that moved no progress, want 0", len(*obs))
	}
	e.assertNothingAdvanced()
}

// A re-key whose COMMIT fails publishes nothing and leaves the counter where it was: the
// allocation rolled back with the move.
func TestProgressSeqOrder_RekeyCommitFailure(t *testing.T) {
	e := newProgressSeqEnv(t)
	insertProgress(t, e.s, "w1", "pr1")
	newPath := "/media/w1.mp4"
	newID := itemIDFromPath(newPath)
	obs := e.observeProgressSeqAlloc("w1", newID)
	e.failAtCommit()

	e.s.updateCodecInfoRepath("w1", newPath, seqOrderProbe())

	if len(*obs) != 1 {
		t.Fatalf("progress_seq allocated %d times, want 1 (the failing commit must come after the allocation for this test to mean anything)", len(*obs))
	}
	e.assertNothingAdvanced()
	if old, moved := e.committedProgressRows("w1"), e.committedProgressRows(newID); old != 1 || moved != 0 {
		t.Errorf("after a failed re-key commit progress rows: old id %d, new id %d; want 1, 0", old, moved)
	}
}

// A re-key onto an id that already has progress for the same profile cannot move the old row
// (it would collide), so it prunes it. That still changes what /progress/all returns, so it
// still bumps progress_seq.
func TestProgressSeqOrder_RekeyPrunesCollidingProgress(t *testing.T) {
	e := newProgressSeqEnv(t)
	newPath := "/media/w1.mp4"
	newID := itemIDFromPath(newPath)
	insertProgress(t, e.s, "w1", "pr1")
	insertProgress(t, e.s, newID, "pr1")
	obs := e.observeProgressSeqAlloc("w1", newID)

	e.s.updateCodecInfoRepath("w1", newPath, seqOrderProbe())

	if old, kept := e.committedProgressRows("w1"), e.committedProgressRows(newID); old != 0 || kept != 1 {
		t.Fatalf("after the re-key progress rows: old id %d, new id %d; want 0, 1 (the old row pruned)", old, kept)
	}
	if len(*obs) != 1 {
		t.Errorf("progress_seq allocated %d times by a re-key that pruned a progress row, want 1: devices keep showing the pruned row", len(*obs))
	}
	e.assertAdvancedOnce()
}
