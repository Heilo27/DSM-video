package normalize

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"dsvideo/backend/internal/transcode"
)

// TASK-1073: verifyOutput judged an output against the SOURCE CONTAINER duration, which
// is the longest of every stream. A subtitle track that outlasts the programme (Frieren
// S02E01: video 24:00.0, audio 24:00.1, one subtitle 24:05.3, container 1470.0s) made a
// complete 1440.2s output look 2% short, so the file was rejected as truncated and never
// converted. A failed verify was also never retired, so a genuinely truncated output was
// rebuilt on every scan.

const longSubSRT = "1\n00:00:00,500 --> 00:00:02,000\nHello\n\n2\n00:00:09,000 --> 00:00:10,000\nStill here\n"

// subOutlastsVideoMKV is a 4s video+audio MKV with an SRT track whose last cue ends at
// 10s: the container reads ~10s while the programme is 4s.
func subOutlastsVideoMKV(t *testing.T, ffmpeg string) string {
	t.Helper()
	dir := t.TempDir()
	srt := filepath.Join(dir, "long.srt")
	if err := os.WriteFile(srt, []byte(longSubSRT), 0o644); err != nil {
		t.Fatal(err)
	}
	src := filepath.Join(dir, "sub outlasts video.mkv")
	if out, err := exec.Command(ffmpeg, "-nostdin", "-y", "-v", "error",
		"-f", "lavfi", "-i", "testsrc=size=320x240:rate=24:duration=4",
		"-f", "lavfi", "-i", "sine=frequency=440:duration=4",
		"-i", srt,
		"-map", "0:v", "-map", "1:a", "-map", "2:s",
		"-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
		"-c:a", "aac", "-c:s", "srt", "-metadata:s:s:0", "language=eng",
		src).CombinedOutput(); err != nil {
		t.Fatalf("build fixture: %v\n%s", err, out)
	}
	return src
}

func TestFixtureContainerDurationIsInflatedBySubtitle(t *testing.T) {
	ffmpeg := ffmpegOrSkip(t)
	ffprobe := ffprobeOrSkip(t)
	src := subOutlastsVideoMKV(t, ffmpeg)
	pr, err := transcode.NewProber(ffprobe).Probe(context.Background(), src)
	if err != nil {
		t.Fatal(err)
	}
	if pr.DurationSecs < 9 {
		t.Fatalf("fixture invalid: container duration %.2fs, want the subtitle to stretch it past 9s", pr.DurationSecs)
	}
	if pr.AVDurationSecs < 3.5 || pr.AVDurationSecs > 5 {
		t.Fatalf("AVDurationSecs = %.2fs, want the ~4s programme length, not the container's %.2fs", pr.AVDurationSecs, pr.DurationSecs)
	}
}

func TestConvertAcceptsSourceWhoseSubtitleOutlastsVideo(t *testing.T) {
	ffmpeg := ffmpegOrSkip(t)
	ffprobe := ffprobeOrSkip(t)
	src := subOutlastsVideoMKV(t, ffmpeg)
	for _, action := range []Action{ActionRemux, ActionEncode} {
		t.Run(action.String(), func(t *testing.T) {
			out, err := Convert(context.Background(), ffmpeg, ffprobe, src, action, 1080)
			if err != nil {
				t.Fatalf("Convert rejected a complete output: %v", err)
			}
			if _, statErr := os.Stat(out); statErr != nil {
				t.Fatalf("verified output missing: %v", statErr)
			}
		})
	}
}

// A genuinely cut-short output is still rejected: 2s of a 10s programme.
func TestVerifyStillRejectsTruncatedOutput(t *testing.T) {
	ffmpeg := ffmpegOrSkip(t)
	ffprobe := ffprobeOrSkip(t)
	src := longProgrammeMKV(t, ffmpeg)

	short := filepath.Join(t.TempDir(), "short.mp4")
	if out, err := exec.Command(ffmpeg, "-nostdin", "-y", "-v", "error", "-i", src,
		"-map", "0:v:0", "-map", "0:a?", "-t", "2", "-c:v", "copy", "-c:a", "aac", short).CombinedOutput(); err != nil {
		t.Fatalf("build truncated output: %v\n%s", err, out)
	}
	err := verifyOutput(context.Background(), ffprobe, src, short)
	if err == nil || !strings.Contains(err.Error(), "truncated") {
		t.Fatalf("verifyOutput accepted a 2s output of a 10s programme (err=%v)", err)
	}
}

// And a truncated output is still caught when the source ALSO has an over-long subtitle:
// the check is against the programme, so the subtitle neither hides nor causes it.
func TestVerifyRejectsTruncatedOutputOfSubOutlastsVideoSource(t *testing.T) {
	ffmpeg := ffmpegOrSkip(t)
	ffprobe := ffprobeOrSkip(t)
	src := subOutlastsVideoMKV(t, ffmpeg)

	short := filepath.Join(t.TempDir(), "short.mp4")
	if out, err := exec.Command(ffmpeg, "-nostdin", "-y", "-v", "error", "-i", src,
		"-map", "0:v:0", "-map", "0:a?", "-map", "0:s", "-t", "2", "-c:v", "copy", "-c:a", "aac", "-c:s", "mov_text", short).CombinedOutput(); err != nil {
		t.Fatalf("build truncated output: %v\n%s", err, out)
	}
	if err := verifyOutput(context.Background(), ffprobe, src, short); err == nil {
		t.Fatal("verifyOutput accepted a 2s output of a 4s programme")
	}
}

func longProgrammeMKV(t *testing.T, ffmpeg string) string {
	t.Helper()
	src := filepath.Join(t.TempDir(), "ten seconds.mkv")
	if out, err := exec.Command(ffmpeg, "-nostdin", "-y", "-v", "error",
		"-f", "lavfi", "-i", "testsrc=size=320x240:rate=24:duration=10",
		"-f", "lavfi", "-i", "sine=frequency=440:duration=10",
		"-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac",
		src).CombinedOutput(); err != nil {
		t.Fatalf("build fixture: %v\n%s", err, out)
	}
	return src
}

// fakeFFmpeg writes a script that ignores its arguments and drops `output` at the last
// argument, standing in for an ffmpeg that exits 0 but wrote a cut-short file.
func fakeFFmpeg(t *testing.T, output string) string {
	t.Helper()
	script := filepath.Join(t.TempDir(), "fake-ffmpeg")
	body := "#!/bin/sh\nfor last; do :; done\ncp '" + output + "' \"$last\"\n"
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	return script
}

// The worker must retire an item whose output fails verify: otherwise every scan pays for
// the same full remux again (Borg vs McEnroe: 463s of 6454s, rebuilt every ~5 minutes).
func TestWorkerRetiresItemWhoseOutputFailsVerify(t *testing.T) {
	ffmpeg := ffmpegOrSkip(t)
	ffprobe := ffprobeOrSkip(t)
	src := longProgrammeMKV(t, ffmpeg)

	short := filepath.Join(t.TempDir(), "short.mp4")
	if out, err := exec.Command(ffmpeg, "-nostdin", "-y", "-v", "error", "-i", src,
		"-t", "2", "-c:v", "copy", "-c:a", "aac", short).CombinedOutput(); err != nil {
		t.Fatalf("build truncated output: %v\n%s", err, out)
	}

	w := NewNormalizeWorker(fakeFFmpeg(t, short), ffprobe, t.TempDir(), 1080, transcode.NewFFmpegLimiter(1), func() bool { return true }, nil)
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	w.process(ctx, queueItem{itemID: "borg", path: src, mediaRoot: filepath.Dir(src)})

	reason, retired := w.PermaFailed()["borg"]
	if !retired {
		t.Fatal("item whose output failed verify was not retired; every scan would re-convert it")
	}
	if !strings.Contains(reason, "truncated") {
		t.Errorf("retirement reason %q does not carry the verify failure", reason)
	}
	if _, err := os.Stat(src); err != nil {
		t.Errorf("original must be left in place: %v", err)
	}

	// A later scan must not queue it again.
	w.Enqueue("borg", src, filepath.Dir(src))
	if len(w.queue) != 0 {
		t.Error("retired item was re-enqueued by a later scan")
	}
}
