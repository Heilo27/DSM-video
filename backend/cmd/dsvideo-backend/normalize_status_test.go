package main

import (
	"encoding/json"
	"testing"

	"dsvideo/backend/internal/normalize"
)

// The status endpoint's value is the retired list; make sure a nil worker and a
// populated one both serialize sanely.
func TestNormalizeStatsSerialize(t *testing.T) {
	var nilW *normalize.NormalizeWorker
	if got := nilW.Stats(); got.Queued != 0 || got.Retired != nil {
		t.Errorf("nil worker Stats() = %+v, want zero value", got)
	}
	if nilW.IsIdleNow() {
		t.Error("nil worker must not report idle")
	}

	w := normalize.NewNormalizeWorker("ffmpeg", "ffprobe", t.TempDir(), 1080, nil, func() bool { return true }, nil)
	w.Enqueue("it_abc", "/v/a.mkv", "/v")
	st := w.Stats()
	if st.Queued != 1 {
		t.Errorf("Queued = %d, want 1", st.Queued)
	}
	if st.MaxHeight != 1080 {
		t.Errorf("MaxHeight = %d, want 1080 (the whole point of the fix)", st.MaxHeight)
	}
	if !w.IsIdleNow() {
		t.Error("IsIdleNow should be true when isIdle returns true")
	}
	if _, err := json.Marshal(st); err != nil {
		t.Errorf("Stats not JSON-serializable: %v", err)
	}
}
