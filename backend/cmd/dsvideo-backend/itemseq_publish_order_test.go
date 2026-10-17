package main

// TASK-919: an item_seq is advertised on /sync only once the row stamped with it is
// committed, and no later item_seq can commit while that row is still being written.
//
// A device sets its delta cursor to the item_seq /sync advertises and next asks only for
// change_seq > cursor. If that number runs ahead of a row still being written, the device's
// cursor passes the row's sequence before the row carries it, and the change (TMDb artwork,
// a corrected codec) never reaches that device.
//
// The observation point is a SQLite trigger that fires INSIDE the writing transaction, after
// the row has its new change_seq but before commit. At that instant it records:
//   - published: what /sync would advertise right now (getSyncSeqs);
//   - committed: the item_seq counter as a SECOND connection sees it. If it already reads
//     the row's sequence, the allocation committed on its own and any other writer could
//     allocate, commit and publish a higher sequence before this row lands.
// Both must still be below the row's sequence.

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"net/url"
	"sync"
	"testing"

	"modernc.org/sqlite"

	"dsvideo/backend/internal/metadata"
	"dsvideo/backend/internal/transcode"
)

type seqObservation struct{ rowSeq, published, committed int64 }

// seqObserver is the Go side of the dsv_test_observe_seq() SQL function. The function is
// registered once per process (modernc registers globally, for connections opened later);
// tests in this file set fn for their own duration and never run in parallel.
var seqObserver struct {
	mu sync.Mutex
	fn func(rowSeq int64)
}

var registerSeqObserverOnce sync.Once

func registerSeqObserver(t *testing.T) {
	t.Helper()
	registerSeqObserverOnce.Do(func() {
		if err := sqlite.RegisterScalarFunction("dsv_test_observe_seq", 1,
			func(_ *sqlite.FunctionContext, args []driver.Value) (driver.Value, error) {
				seq, _ := args[0].(int64)
				seqObserver.mu.Lock()
				fn := seqObserver.fn
				seqObserver.mu.Unlock()
				if fn != nil {
					fn(seq)
				}
				return nil, nil
			}); err != nil {
			panic(err)
		}
	})
}

type seqOrderEnv struct {
	*qaEnv
	reader *sql.DB // second connection: sees only committed state
	obs    []seqObservation
}

const seqOrderStart = 5

// newSeqOrderEnv builds a server whose connections all carry dsv_test_observe_seq, with
// item_seq committed and published at seqOrderStart.
func newSeqOrderEnv(t *testing.T) *seqOrderEnv {
	t.Helper()
	registerSeqObserver(t) // before any connection of this test's DB is opened
	e := &seqOrderEnv{qaEnv: newQAEnv(t)}
	e.s.metaSemaphore = make(chan struct{}, 2)
	e.s.metaInFlight = map[string]bool{}
	reader, err := sql.Open("sqlite", e.dbPath+"?_pragma=busy_timeout(30000)")
	if err != nil {
		t.Fatalf("open reader: %v", err)
	}
	t.Cleanup(func() { reader.Close() })
	e.reader = reader
	if _, err := e.db.Exec(`UPDATE sync_state SET value = ? WHERE key = 'item_seq'`, seqOrderStart); err != nil {
		t.Fatalf("seed item_seq: %v", err)
	}
	e.s.cachedItemSeq.Store(seqOrderStart)

	seqObserver.mu.Lock()
	seqObserver.fn = func(rowSeq int64) {
		published, _ := e.s.getSyncSeqs()
		var committed int64
		if err := e.reader.QueryRow(`SELECT value FROM sync_state WHERE key = 'item_seq'`).Scan(&committed); err != nil {
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

// observe fires the observer whenever the row that was oldID gets a change_seq written.
func (e *seqOrderEnv) observe(oldID string) {
	e.t.Helper()
	if _, err := e.db.Exec(`CREATE TRIGGER obs_` + oldID + ` AFTER UPDATE OF change_seq ON items
		WHEN OLD.id = '` + oldID + `' BEGIN SELECT dsv_test_observe_seq(NEW.change_seq); END`); err != nil {
		e.t.Fatalf("observer trigger: %v", err)
	}
}

// failWrites makes every change_seq write to oldID abort.
func (e *seqOrderEnv) failWrites(oldID string) {
	e.t.Helper()
	if _, err := e.db.Exec(`CREATE TRIGGER fail_` + oldID + ` BEFORE UPDATE OF change_seq ON items
		WHEN OLD.id = '` + oldID + `' BEGIN SELECT RAISE(ABORT, 'injected write failure'); END`); err != nil {
		e.t.Fatalf("failure trigger: %v", err)
	}
}

func (e *seqOrderEnv) committedSeq() int64 {
	e.t.Helper()
	var v int64
	if err := e.reader.QueryRow(`SELECT value FROM sync_state WHERE key = 'item_seq'`).Scan(&v); err != nil {
		e.t.Fatalf("committed item_seq: %v", err)
	}
	return v
}

func (e *seqOrderEnv) rowSeq(id string) int64 {
	e.t.Helper()
	var v int64
	if err := e.db.QueryRow(`SELECT COALESCE(change_seq, 0) FROM items WHERE id = ?`, id).Scan(&v); err != nil {
		e.t.Fatalf("change_seq of %s: %v", id, err)
	}
	return v
}

// assertWrittenInOrder: exactly one observed write of id, nothing advertised or committed
// ahead of it while it was uncommitted, and afterwards the row is committed at that
// sequence and /sync advertises it.
func (e *seqOrderEnv) assertWrittenInOrder(id string) {
	e.t.Helper()
	if len(e.obs) != 1 {
		e.t.Fatalf("observed %d change_seq writes, want 1: %+v", len(e.obs), e.obs)
	}
	o := e.obs[0]
	if o.rowSeq <= seqOrderStart {
		e.t.Fatalf("row written at change_seq %d, want a fresh sequence above %d", o.rowSeq, seqOrderStart)
	}
	if o.published >= o.rowSeq {
		e.t.Errorf("/sync advertised item_seq %d while the row stamped %d was uncommitted: a device syncing then never fetches it", o.published, o.rowSeq)
	}
	if o.committed >= o.rowSeq {
		e.t.Errorf("item_seq %d was already committed while the row stamped %d was uncommitted: another writer can commit and publish past it", o.committed, o.rowSeq)
	}
	if got := e.rowSeq(id); got != o.rowSeq {
		e.t.Errorf("row %s committed at change_seq %d, observed write at %d", id, got, o.rowSeq)
	}
	if published, _ := e.s.getSyncSeqs(); published < o.rowSeq {
		e.t.Errorf("after commit /sync advertises %d, below the committed row's %d: devices never ask for it", published, o.rowSeq)
	}
}

// assertNothingAdvanced: a write that failed must leave the counter, the advertised value
// and the row's change_seq exactly where they were.
func (e *seqOrderEnv) assertNothingAdvanced(id string, rowBefore int64) {
	e.t.Helper()
	if published, _ := e.s.getSyncSeqs(); published != seqOrderStart {
		e.t.Errorf("/sync advertises %d after a failed write, want %d unchanged", published, seqOrderStart)
	}
	if c := e.committedSeq(); c != seqOrderStart {
		e.t.Errorf("item_seq counter %d after a failed write, want %d unchanged", c, seqOrderStart)
	}
	if got := e.rowSeq(id); got != rowBefore {
		e.t.Errorf("row %s change_seq %d after a failed write, want %d", id, got, rowBefore)
	}
}

func (e *seqOrderEnv) enrich(id string) {
	e.t.Helper()
	fake := newFakeTMDb(e.t, func(p string, _ url.Values) (int, string) {
		switch p {
		case "/search/movie":
			return 200, `{"results":[{"id":10,"title":"Up","release_date":"2009-05-29"}]}`
		case "/movie/10":
			return 200, movieJSON(10, "PG")
		}
		return 404, `{}`
	})
	e.s.fetchAndStoreMetadataWithClient(context.Background(), id,
		metadata.ParsedFilename{Title: "Up", Year: 2009}, "movie", fake.client())
}

func seqOrderProbe() *transcode.ProbeResult {
	return &transcode.ProbeResult{Container: "mp4", VideoCodec: "h264", AudioCodec: "aac", DurationSecs: 60}
}

func TestItemSeqOrder_MetadataEnrichment(t *testing.T) {
	e := newSeqOrderEnv(t)
	e.seedItem("it_up", "", nil)
	e.observe("it_up")
	e.enrich("it_up")
	e.assertWrittenInOrder("it_up")
	var title string
	_ = e.db.QueryRow(`SELECT title FROM items WHERE id = 'it_up'`).Scan(&title)
	if title != "M10" {
		t.Errorf("enrichment did not land: title %q, want M10 (fixture)", title)
	}
}

func TestItemSeqOrder_MetadataEnrichmentFailure(t *testing.T) {
	e := newSeqOrderEnv(t)
	e.seedItem("it_up", "", nil)
	before := e.rowSeq("it_up")
	e.failWrites("it_up")
	e.enrich("it_up")
	e.assertNothingAdvanced("it_up", before)
}

func TestItemSeqOrder_CodecUpdate(t *testing.T) {
	e := newSeqOrderEnv(t)
	e.seedItem("it_codec", "", nil)
	e.observe("it_codec")
	e.s.updateCodecInfo("it_codec", seqOrderProbe())
	e.assertWrittenInOrder("it_codec")
}

func TestItemSeqOrder_CodecUpdateFailure(t *testing.T) {
	e := newSeqOrderEnv(t)
	e.seedItem("it_codec", "", nil)
	before := e.rowSeq("it_codec")
	e.failWrites("it_codec")
	e.s.updateCodecInfo("it_codec", seqOrderProbe())
	e.assertNothingAdvanced("it_codec", before)
}

// Different-path conversion: the row is re-keyed to the new path's id.
func TestItemSeqOrder_NormalizeRekey(t *testing.T) {
	e := newSeqOrderEnv(t)
	e.seedItem("it_rk", "", nil)
	e.observe("it_rk")
	newPath := "/media/it_rk.mp4"
	e.s.updateCodecInfoRepath("it_rk", newPath, seqOrderProbe())
	e.assertWrittenInOrder(itemIDFromPath(newPath))
}

// Same-path conversion: path + codec repointed on the existing id.
func TestItemSeqOrder_NormalizeSamePath(t *testing.T) {
	e := newSeqOrderEnv(t)
	e.seedItem("it_sp", "", nil)
	var path string
	_ = e.db.QueryRow(`SELECT path FROM items WHERE id = 'it_sp'`).Scan(&path)
	id := itemIDFromPath(path)
	if _, err := e.db.Exec(`UPDATE items SET id = ? WHERE id = 'it_sp'`, id); err != nil {
		t.Fatalf("re-key fixture to its path id: %v", err)
	}
	e.observe(id)
	e.s.updateCodecInfoRepath(id, path, seqOrderProbe())
	e.assertWrittenInOrder(id)
}

// Both arms failing: the re-key and its path-only fallback each roll back; nothing is
// advertised and the counter is untouched.
func TestItemSeqOrder_NormalizeFailure(t *testing.T) {
	e := newSeqOrderEnv(t)
	e.seedItem("it_rkf", "", nil)
	before := e.rowSeq("it_rkf")
	e.failWrites("it_rkf")
	e.s.updateCodecInfoRepath("it_rkf", "/media/it_rkf.mp4", seqOrderProbe())
	e.assertNothingAdvanced("it_rkf", before)
}
