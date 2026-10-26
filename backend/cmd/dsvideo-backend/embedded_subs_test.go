package main

// TASK-1071 — embedded text subtitles are extracted at ingest (scan / normalize swap),
// in ONE ffmpeg pass per file, keep their language + title, and /playback never waits.
//
// These tests drive the mechanism with stub ffprobe/ffmpeg shell scripts. The ffmpeg stub
// appends its argv to a log (one line per invocation), optionally blocks on a gate file,
// and creates every "*.part" output it was asked for.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"dsvideo/backend/internal/transcode"
)

const (
	subStreamEn   = `{"index":2,"codec_type":"subtitle","codec_name":"subrip","tags":{"language":"en"},"disposition":{"default":1}}`
	subStreamFr   = `{"index":3,"codec_type":"subtitle","codec_name":"ass","tags":{"language":"fr","title":"Dialogue"}}`
	subStreamPGS  = `{"index":4,"codec_type":"subtitle","codec_name":"hdmv_pgs_subtitle","tags":{"language":"de"}}`
	subVideoH264  = `{"index":0,"codec_type":"video","codec_name":"h264","codec_tag_string":"avc1","width":1920,"height":1080}`
	subAudioAAC   = `{"index":1,"codec_type":"audio","codec_name":"aac","channels":2}`
	subTestItemID = "sub-item"
)

type embeddedSubsWorld struct {
	s       *Server
	path    string
	ffLog   string
	gate    string
	movies  string
	probeJS string
}

// newEmbeddedSubsWorld wires a bare Server (no scan) with the stubs and a video file inside
// the movies root. gated=true makes ffmpeg block until the gate file exists.
func newEmbeddedSubsWorld(t *testing.T, gated bool, streams ...string) *embeddedSubsWorld {
	t.Helper()
	s, _ := newProfilesTestServer(t)
	bin := t.TempDir()
	ffLog := filepath.Join(bin, "ffmpeg.log")
	gate := filepath.Join(bin, "gate")

	body := `{"format":{"format_name":"matroska,webm","duration":"60.0"},"streams":[` + strings.Join(streams, ",") + `]}`
	ffprobe := filepath.Join(bin, "ffprobe")
	ffmpeg := filepath.Join(bin, "ffmpeg")
	if err := os.WriteFile(ffprobe, []byte("#!/bin/sh\ncat <<'EOF'\n"+body+"\nEOF\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	script := "#!/bin/sh\necho \"$*\" >> " + ffLog + "\n"
	if gated {
		script += "while [ ! -e " + gate + " ]; do sleep 0.02; done\n"
	}
	script += "for a in \"$@\"; do case \"$a\" in *.part) printf '1\\n00:00:01,000 --> 00:00:02,000\\nhi\\n' > \"$a\";; esac; done\n"
	if err := os.WriteFile(ffmpeg, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}

	movies := filepath.Join(t.TempDir(), "movies")
	path := filepath.Join(movies, "Film.mkv")
	writeVideo(t, path)

	s.cfg.MoviesPath = movies
	s.cfg.FFmpegPath = ffmpeg
	s.cfg.TranscodeDir = t.TempDir()
	s.prober = transcode.NewProber(ffprobe)
	s.ffmpegLimiter = transcode.NewFFmpegLimiter(2)
	return &embeddedSubsWorld{s: s, path: path, ffLog: ffLog, gate: gate, movies: movies}
}

func (w *embeddedSubsWorld) ffmpegRuns(t *testing.T) []string {
	t.Helper()
	raw, err := os.ReadFile(w.ffLog)
	if err != nil {
		return nil
	}
	return strings.Split(strings.TrimSpace(string(raw)), "\n")
}

func (w *embeddedSubsWorld) waitMeta(t *testing.T, itemID string) {
	t.Helper()
	meta := filepath.Join(w.s.embeddedSubsDir(itemID), embeddedSubsMetaFile)
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(meta); err == nil {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("embedded-subtitle ingest for %s never finished (no %s)", itemID, meta)
}

func trackNames(tracks []transcode.SubtitleTrack) []string {
	out := make([]string, 0, len(tracks))
	for _, tr := range tracks {
		out = append(out, tr.Name)
	}
	return out
}

func TestEmbeddedSubsIngestSinglePassKeepsLanguageAndTitle(t *testing.T) {
	w := newEmbeddedSubsWorld(t, false, subVideoH264, subAudioAAC, subStreamEn, subStreamFr, subStreamPGS)
	w.s.ensureEmbeddedSubs(subTestItemID, w.path, nil)
	w.waitMeta(t, subTestItemID)

	runs := w.ffmpegRuns(t)
	if len(runs) != 1 {
		t.Fatalf("ffmpeg ran %d times for 2 text streams, want 1 single pass: %v", len(runs), runs)
	}
	if !strings.Contains(runs[0], "-map 0:2") || !strings.Contains(runs[0], "-map 0:3") || strings.Contains(runs[0], "-map 0:4") {
		t.Errorf("single pass must map both text streams and not the image stream: %q", runs[0])
	}
	dir := w.s.embeddedSubsDir(subTestItemID)
	for _, n := range []string{"stream_2.srt", "stream_3.srt"} {
		if _, err := os.Stat(filepath.Join(dir, n)); err != nil {
			t.Errorf("missing %s: %v", n, err)
		}
	}
	if parts, _ := filepath.Glob(filepath.Join(dir, "*.part")); len(parts) != 0 {
		t.Errorf("leftover partial files: %v", parts)
	}

	// First play after ingest, with NO probe on the request: full, correctly named list.
	tracks := w.s.collectEmbeddedSubtitles(subTestItemID, w.path, 0, nil)
	got := strings.Join(trackNames(tracks), "|")
	if got != "English|Dialogue|German" {
		t.Fatalf("track names = %q, want English|Dialogue|German (language/title kept, image listed)", got)
	}
	if tracks[0].Language != "en" || !tracks[0].Default || tracks[0].Path == "" || tracks[0].Type != "full" {
		t.Errorf("english track fields wrong: %+v", tracks[0])
	}
	if tracks[2].Type != "image" || tracks[2].Path != "" {
		t.Errorf("image track should be listed without a path: %+v", tracks[2])
	}
	if n := len(w.ffmpegRuns(t)); n != 1 {
		t.Errorf("listing must not run ffmpeg again, runs=%d", n)
	}
}

func TestEmbeddedSubsPlayDuringExtractionDoesNotWait(t *testing.T) {
	w := newEmbeddedSubsWorld(t, true, subVideoH264, subStreamEn, subStreamPGS)
	probe := &transcode.ProbeResult{EmbeddedSubs: []transcode.EmbeddedSubtitle{
		{Index: 1, Codec: "subrip", Language: "en"},
		{Index: 2, Codec: "hdmv_pgs_subtitle", Language: "de", IsImage: true},
	}}

	start := time.Now()
	first := w.s.collectEmbeddedSubtitles(subTestItemID, w.path, 0, probe) // ffmpeg is gated shut
	if d := time.Since(start); d > 2*time.Second {
		t.Fatalf("collectEmbeddedSubtitles blocked %v on a running extraction", d)
	}
	if got := strings.Join(trackNames(first), "|"); got != "German" {
		t.Errorf("mid-extraction play should list only what is ready (image track), got %q", got)
	}

	if err := os.WriteFile(w.gate, nil, 0o644); err != nil { // let ffmpeg finish
		t.Fatal(err)
	}
	w.waitMeta(t, subTestItemID)
	second := w.s.collectEmbeddedSubtitles(subTestItemID, w.path, 0, probe)
	if got := strings.Join(trackNames(second), "|"); got != "English|German" {
		t.Errorf("next play should include the extracted track, got %q", got)
	}
	if n := len(w.ffmpegRuns(t)); n != 1 {
		t.Errorf("play + queued ingest must collapse to one extraction, runs=%d", n)
	}
}

func TestEmbeddedSubsNoTextStreamsRecordedWithoutFFmpeg(t *testing.T) {
	w := newEmbeddedSubsWorld(t, false, subVideoH264, subAudioAAC)
	w.s.ensureEmbeddedSubs(subTestItemID, w.path, nil)
	w.waitMeta(t, subTestItemID)
	if n := len(w.ffmpegRuns(t)); n != 0 {
		t.Errorf("a file with no text subs must not run ffmpeg, runs=%d", n)
	}
	// Recorded as done: a second ensure is a no-op (no re-probe-driven re-extraction).
	w.s.ensureEmbeddedSubs(subTestItemID, w.path, nil)
	if tr := w.s.collectEmbeddedSubtitles(subTestItemID, w.path, 0, nil); len(tr) != 0 {
		t.Errorf("expected no tracks, got %v", tr)
	}
}

func TestEmbeddedSubsStaleCacheNeverServedAndRegenerates(t *testing.T) {
	w := newEmbeddedSubsWorld(t, false, subVideoH264, subStreamEn)
	w.s.ensureEmbeddedSubs(subTestItemID, w.path, nil)
	w.waitMeta(t, subTestItemID)

	// The file is replaced (as a normalize swap does): different size.
	if err := os.WriteFile(w.path, []byte("a different, longer replacement file body"), 0o644); err != nil {
		t.Fatal(err)
	}
	if tr := w.s.collectEmbeddedSubtitles(subTestItemID, w.path, 0, nil); len(tr) != 0 {
		t.Fatalf("stale cache must not be served, got %v", trackNames(tr))
	}
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) && len(w.ffmpegRuns(t)) < 2 {
		time.Sleep(20 * time.Millisecond)
	}
	if n := len(w.ffmpegRuns(t)); n != 2 {
		t.Fatalf("stale cache should trigger one re-extraction, ffmpeg runs=%d", n)
	}
	w.waitFresh(t)
	if tr := w.s.collectEmbeddedSubtitles(subTestItemID, w.path, 0, nil); len(tr) != 1 || tr[0].Name != "English" {
		t.Errorf("regenerated cache should list English, got %v", trackNames(tr))
	}
}

// waitFresh waits until the cache for subTestItemID matches the file on disk again.
func (w *embeddedSubsWorld) waitFresh(t *testing.T) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if _, st := readEmbeddedSubsMeta(w.s.embeddedSubsDir(subTestItemID), w.path); st == embeddedSubsCurrent {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("cache never became current")
}

func TestEmbeddedSubsPathOutsideMediaRootIsRefused(t *testing.T) {
	w := newEmbeddedSubsWorld(t, false, subVideoH264, subStreamEn)
	outside := filepath.Join(t.TempDir(), "Elsewhere.mkv")
	writeVideo(t, outside)
	w.s.ensureEmbeddedSubs("outside", outside, nil)
	if tr := w.s.collectEmbeddedSubtitles("outside", outside, 0, nil); tr != nil {
		t.Errorf("out-of-root path listed tracks: %v", tr)
	}
	time.Sleep(200 * time.Millisecond)
	if n := len(w.ffmpegRuns(t)); n != 0 {
		t.Errorf("ffmpeg ran for an out-of-root path (%d runs)", n)
	}
}

func TestEmbeddedSubsLegacyCacheStillServed(t *testing.T) {
	w := newEmbeddedSubsWorld(t, true, subVideoH264, subStreamEn) // gated: no new extraction completes
	dir := w.s.embeddedSubsDir(subTestItemID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "stream_1.srt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	tr := w.s.collectEmbeddedSubtitles(subTestItemID, w.path, 0, nil)
	if len(tr) != 1 || tr[0].Name != "Subtitles" || tr[0].Language != "und" {
		t.Errorf("pre-meta cache should still be listed generically, got %+v", tr)
	}
	if err := os.WriteFile(w.gate, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	w.waitMeta(t, subTestItemID)
}

func TestEmbeddedSubsSwapRekeyMovesCacheToNewItemID(t *testing.T) {
	w := newEmbeddedSubsWorld(t, false, subVideoH264, subStreamEn)
	oldID := itemIDFromPath(w.path)
	w.s.ensureEmbeddedSubs(oldID, w.path, nil)
	w.waitMeta(t, oldID)

	// The swap: Film.mkv becomes Film.mp4 and the item re-keys to the new path's id.
	newPath := filepath.Join(w.movies, "Film.mp4")
	writeVideo(t, newPath)
	newID := itemIDFromPath(newPath)
	if _, err := w.s.db.Exec(`INSERT INTO items(id, library_id, type, title, path, duration_seconds, added_at, updated_at)
		VALUES(?, 'lib_movies', 'movie', 'Film', ?, 60, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')`, newID, newPath); err != nil {
		t.Fatalf("seed re-keyed item: %v", err)
	}
	probe := &transcode.ProbeResult{EmbeddedSubs: []transcode.EmbeddedSubtitle{{Index: 1, Codec: "subrip", Language: "en"}}}
	w.s.refreshEmbeddedSubsAfterSwap(oldID, newPath, probe)
	w.waitMeta(t, newID)

	if _, err := os.Stat(w.s.embeddedSubsDir(oldID)); !os.IsNotExist(err) {
		t.Errorf("orphaned cache for the old id should be removed, stat err = %v", err)
	}
	if tr := w.s.collectEmbeddedSubtitles(newID, newPath, 0, nil); len(tr) != 1 || tr[0].Name != "English" {
		t.Errorf("first play of the converted file should list English, got %v", trackNames(tr))
	}
}

func TestEmbeddedSubsSwapPathOnlyRepointKeepsOldID(t *testing.T) {
	w := newEmbeddedSubsWorld(t, false, subVideoH264, subStreamEn)
	// Re-key fell back to a path-only repoint: no row exists for the new path's id.
	const oldID = "legacy-id"
	newPath := filepath.Join(w.movies, "Film.mp4")
	writeVideo(t, newPath)
	probe := &transcode.ProbeResult{EmbeddedSubs: []transcode.EmbeddedSubtitle{{Index: 1, Codec: "subrip", Language: "en"}}}
	w.s.refreshEmbeddedSubsAfterSwap(oldID, newPath, probe)
	w.waitMeta(t, oldID)
	if tr := w.s.collectEmbeddedSubtitles(oldID, newPath, 0, nil); len(tr) != 1 {
		t.Errorf("cache should live under the id the row still has, got %v", trackNames(tr))
	}
}
