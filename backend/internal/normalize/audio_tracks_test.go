package normalize

import (
	"context"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"dsvideo/backend/internal/transcode"
)

// FR-063: normalizing a library file keeps EVERY audio track, with its language and title.
// The old -map 0:a:0? kept only the first, and the worker then deleted the original, so a
// second language or a commentary track was gone for good.

func ffprobeOrSkip(t *testing.T) string {
	t.Helper()
	path, err := exec.LookPath("ffprobe")
	if err != nil {
		t.Skip("ffprobe not installed")
	}
	return path
}

// twoAudioMKV builds a short MKV with an English AAC track and a French AC-3 track titled
// "Commentary", the shape of a typical rip with a second language or a commentary.
func twoAudioMKV(t *testing.T, ffmpeg string) string {
	t.Helper()
	src := filepath.Join(t.TempDir(), "two audio.mkv")
	out, err := exec.Command(ffmpeg, "-nostdin", "-y", "-v", "error",
		"-f", "lavfi", "-i", "testsrc=size=320x240:rate=24:duration=4",
		"-f", "lavfi", "-i", "sine=frequency=440:duration=4",
		"-f", "lavfi", "-i", "sine=frequency=660:duration=4",
		"-map", "0:v", "-map", "1:a", "-map", "2:a",
		"-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
		"-c:a:0", "aac", "-c:a:1", "ac3",
		"-metadata:s:a:0", "language=eng",
		"-metadata:s:a:1", "language=fra", "-metadata:s:a:1", "title=Commentary",
		src).CombinedOutput()
	if err != nil {
		t.Fatalf("build fixture: %v\n%s", err, out)
	}
	return src
}

func TestNormalizeArgsMapEveryAudioTrack(t *testing.T) {
	for _, action := range []Action{ActionRemux, ActionEncode} {
		args := strings.Join(buildFFmpegArgs("in.mkv", "out.mp4", action, 1080, "", nil), " ")
		if !strings.Contains(args, "-map 0:a?") {
			t.Errorf("%s: args do not map every audio track: %s", action, args)
		}
		if strings.Contains(args, "0:a:0") {
			t.Errorf("%s: args still map only the first audio track: %s", action, args)
		}
	}
}

func TestConvertKeepsEveryAudioTrackWithLanguageAndTitle(t *testing.T) {
	ffmpeg := ffmpegOrSkip(t)
	ffprobe := ffprobeOrSkip(t)
	src := twoAudioMKV(t, ffmpeg)

	for _, action := range []Action{ActionRemux, ActionEncode} {
		t.Run(action.String(), func(t *testing.T) {
			out, err := Convert(context.Background(), ffmpeg, ffprobe, src, action, 1080)
			if err != nil {
				t.Fatalf("Convert: %v", err)
			}
			pr, err := transcode.NewProber(ffprobe).Probe(context.Background(), out)
			if err != nil {
				t.Fatalf("probe output: %v", err)
			}
			if len(pr.AudioStreams) != 2 {
				t.Fatalf("output has %d audio streams, want 2: %+v", len(pr.AudioStreams), pr.AudioStreams)
			}
			if got := pr.AudioStreams[0].Language; got != "eng" {
				t.Errorf("track 1 language = %q, want eng", got)
			}
			if got := pr.AudioStreams[1].Language; got != "fra" {
				t.Errorf("track 2 language = %q, want fra", got)
			}
			if got := pr.AudioStreams[1].Title; got != "Commentary" {
				t.Errorf("track 2 title = %q, want Commentary", got)
			}
			for i, a := range pr.AudioStreams {
				if a.Codec != "aac" {
					t.Errorf("track %d codec = %q, want aac", i+1, a.Codec)
				}
			}
		})
	}
}

// The verify step is the last guard before the original is deleted, so it must refuse an
// output that lost a track even when ffmpeg exited 0.
func TestVerifyRejectsAnOutputMissingAnAudioTrack(t *testing.T) {
	ffmpeg := ffmpegOrSkip(t)
	ffprobe := ffprobeOrSkip(t)
	src := twoAudioMKV(t, ffmpeg)

	lossy := filepath.Join(t.TempDir(), "one track.mp4")
	if out, err := exec.Command(ffmpeg, "-nostdin", "-y", "-v", "error", "-i", src,
		"-map", "0:v:0", "-map", "0:a:0", "-c:v", "copy", "-c:a", "aac", lossy).CombinedOutput(); err != nil {
		t.Fatalf("build lossy output: %v\n%s", err, out)
	}
	err := verifyOutput(context.Background(), ffprobe, src, lossy)
	if err == nil || !strings.Contains(err.Error(), "audio track") {
		t.Fatalf("verifyOutput accepted an output with 1 of 2 audio tracks (err=%v)", err)
	}
}
