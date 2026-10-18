package normalize

// TASK-1001 — what the normalize worker covers, and the limits it honours doing so.
//
// TASK-990 / TASK-1002 made the scanner index the older containers (.wmv .mpg .flv .3gp
// .rm .rmvb .divx .asf .ogv .ogm .f4v ...). They are never direct played, so
// needs_transcode is true and the scanner enqueues them here. This pins the FRD-000 M1
// statement that they get NO special path: the same Decide rule, the same idle gate, the
// same shared ffmpeg limiter, the same backup-then-retention handling as any .mkv.

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"dsvideo/backend/internal/transcode"
)

// Every container name the prober can report for the TASK-990/1002 extensions normalises
// (Decide != Skip), whatever its codecs: none of them is a compatible container, so none
// can be classified as already direct-playable.
func TestScope_EveryLegacyContainerIsNormalised(t *testing.T) {
	cases := []struct {
		ext       string
		container string
		video     string
		audio     string
		want      Action
	}{
		{".wmv", "asf", "wmv3", "wmav2", ActionEncode},
		{".asf", "asf", "wmv3", "wmav2", ActionEncode},
		{".mpg", "mpeg", "mpeg2", "mp2", ActionEncode},
		{".mpeg", "mpeg", "mpeg2", "ac3", ActionEncode},
		{".vob", "mpeg", "mpeg2", "ac3", ActionEncode},
		{".m2ts", "mpegts", "h264", "ac3", ActionRemux},
		{".mts", "mpegts", "h264", "aac", ActionRemux},
		{".flv", "flv", "h264", "aac", ActionRemux},
		{".3gp", "3gp", "h264", "aac", ActionRemux},
		{".rm", "rm", "rv40", "cook", ActionEncode},
		{".rmvb", "rm", "rv40", "cook", ActionEncode},
		{".divx", "avi", "mpeg4", "mp3", ActionEncode},
		{".ogv", "ogg", "theora", "vorbis", ActionEncode},
		{".ogm", "ogg", "theora", "vorbis", ActionEncode},
		{".f4v", "f4v", "h264", "aac", ActionRemux},
		{".ts", "mpegts", "h264", "aac", ActionRemux},
	}
	for _, tc := range cases {
		t.Run(tc.ext, func(t *testing.T) {
			p := &transcode.ProbeResult{VideoCodec: tc.video, AudioCodec: tc.audio, Container: tc.container}
			if got := Decide(p, tc.ext); got != tc.want {
				t.Errorf("Decide(%s %s/%s in %s) = %v, want %v", tc.ext, tc.video, tc.audio, tc.container, got, tc.want)
			}
		})
	}
}

// fakeTools writes a stub ffprobe (reports a .wmv: asf container, wmv3 video) and a stub
// ffmpeg that leaves a marker file when run. A test that must prove ffmpeg was NOT
// started asserts the marker is absent.
func fakeTools(t *testing.T) (ffmpeg, ffprobe, marker string) {
	t.Helper()
	dir := t.TempDir()
	marker = filepath.Join(dir, "ffmpeg-ran")
	ffprobe = filepath.Join(dir, "ffprobe")
	ffmpeg = filepath.Join(dir, "ffmpeg")
	probeJSON := `{"format":{"format_name":"asf","duration":"60.0"},"streams":[` +
		`{"codec_type":"video","codec_name":"wmv3","width":640,"height":480},` +
		`{"codec_type":"audio","codec_name":"wmav2","channels":2}]}`
	if err := os.WriteFile(ffprobe, []byte("#!/bin/sh\ncat <<'EOF'\n"+probeJSON+"\nEOF\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(ffmpeg, []byte("#!/bin/sh\ntouch '"+marker+"'\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return ffmpeg, ffprobe, marker
}

// A job never starts ffmpeg while the server is busy (live playback / a recent session),
// and the original file is left exactly where it was.
func TestScope_BusyServerNeverStartsAConversion(t *testing.T) {
	ffmpeg, ffprobe, marker := fakeTools(t)
	media := t.TempDir()
	src := filepath.Join(media, "clip.wmv")
	if err := os.WriteFile(src, []byte("video"), 0o644); err != nil {
		t.Fatal(err)
	}
	w := NewNormalizeWorker(ffmpeg, ffprobe, t.TempDir(), 720,
		transcode.NewFFmpegLimiter(2), func() bool { return false }, nil)

	ctx, cancel := context.WithTimeout(context.Background(), 400*time.Millisecond)
	defer cancel()
	w.process(ctx, queueItem{itemID: "wmv1", path: src, mediaRoot: media})

	if _, err := os.Stat(marker); err == nil {
		t.Error("ffmpeg was started while the server was busy")
	}
	if _, err := os.Stat(src); err != nil {
		t.Errorf("original disturbed while busy: %v", err)
	}
}

// With the server idle but every shared ffmpeg slot taken (a viewer's transcode), the
// worker yields rather than competing: ffmpeg is not started and the slot stays the
// viewer's.
func TestScope_SaturatedLimiterMakesTheWorkerYield(t *testing.T) {
	ffmpeg, ffprobe, marker := fakeTools(t)
	media := t.TempDir()
	src := filepath.Join(media, "clip.wmv")
	if err := os.WriteFile(src, []byte("video"), 0o644); err != nil {
		t.Fatal(err)
	}
	lim := transcode.NewFFmpegLimiter(1)
	if err := lim.Acquire(context.Background()); err != nil { // the viewer's slot
		t.Fatal(err)
	}
	w := NewNormalizeWorker(ffmpeg, ffprobe, t.TempDir(), 720, lim, func() bool { return true }, nil)

	w.process(context.Background(), queueItem{itemID: "wmv2", path: src, mediaRoot: media})

	if _, err := os.Stat(marker); err == nil {
		t.Error("ffmpeg was started although the shared limiter had no free slot")
	}
	if _, err := os.Stat(src); err != nil {
		t.Errorf("original disturbed by a yielded job: %v", err)
	}
	if lim.TryAcquire(context.Background(), 10*time.Millisecond) {
		t.Error("worker took a slot it should have yielded")
	}
}

// An original is only ever moved into the backup tree (mtime reset to now = the retention
// clock), never deleted outright; the retention window then reclaims it.
func TestScope_OriginalsAreBackedUpThenReapedByRetention(t *testing.T) {
	media := t.TempDir()
	backup := t.TempDir()
	w := &NormalizeWorker{backupDir: backup}

	var srcs, dests []string
	for _, name := range []string{"a.wmv", "b.rmvb", "c.f4v", "d.mpg"} {
		src := filepath.Join(media, name)
		if err := os.WriteFile(src, []byte("video"), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := w.backupOriginal(src, media); err != nil {
			t.Fatal(err)
		}
		srcs = append(srcs, src)
		dests = append(dests, filepath.Join(backup, name))
	}
	for i := range srcs {
		if exists(srcs[i]) {
			t.Errorf("%s still at its source after backup", srcs[i])
		}
		if !exists(dests[i]) {
			t.Errorf("%s missing from the backup tree", dests[i])
		}
	}

	w.reapBackups(7) // all brand new: nothing is within reach of the reaper
	for _, d := range dests {
		if !exists(d) {
			t.Errorf("%s reaped inside its retention window", d)
		}
	}

	// Age the first past the window; three newer backups remain, so it is reclaimable.
	old := time.Now().Add(-8 * day)
	if err := os.Chtimes(dests[0], old, old); err != nil {
		t.Fatal(err)
	}
	w.reapBackups(7)
	if exists(dests[0]) {
		t.Error("expired backup outside the newest three was not reaped")
	}
	for _, d := range dests[1:] {
		if !exists(d) {
			t.Errorf("%s reaped though inside the window", d)
		}
	}
}
