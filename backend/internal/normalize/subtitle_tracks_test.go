package normalize

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"dsvideo/backend/internal/transcode"
)

// FR-063 / TASK-1070: normalizing a library file never costs a title a text subtitle
// track. The old args mapped video and audio only, so every subtitle stream was dropped,
// and the worker then deleted the original.

const testSRT = "1\n00:00:00,500 --> 00:00:02,000\nHello\n\n2\n00:00:02,500 --> 00:00:03,500\nWorld\n"

const testASS = `[Script Info]
ScriptType: v4.00+
PlayResX: 384
PlayResY: 288

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,2,2,10,10,10,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.50,0:00:02.00,Default,,0,0,0,,Bonjour
`

// subtitledMKV builds a short MKV with one audio track plus an English SRT track titled
// "Full" and a French ASS track titled "Signs", the shape of a typical fansub release.
func subtitledMKV(t *testing.T, ffmpeg string) string {
	t.Helper()
	dir := t.TempDir()
	srt := filepath.Join(dir, "en.srt")
	ass := filepath.Join(dir, "fr.ass")
	if err := os.WriteFile(srt, []byte(testSRT), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(ass, []byte(testASS), 0o644); err != nil {
		t.Fatal(err)
	}
	src := filepath.Join(dir, "subtitled.mkv")
	out, err := exec.Command(ffmpeg, "-nostdin", "-y", "-v", "error",
		"-f", "lavfi", "-i", "testsrc=size=320x240:rate=24:duration=4",
		"-f", "lavfi", "-i", "sine=frequency=440:duration=4",
		"-i", srt, "-i", ass,
		"-map", "0:v", "-map", "1:a", "-map", "2:s", "-map", "3:s",
		"-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
		"-c:a", "aac", "-c:s:0", "srt", "-c:s:1", "ass",
		"-metadata:s:s:0", "language=eng", "-metadata:s:s:0", "title=Full",
		"-metadata:s:s:1", "language=fre", "-metadata:s:s:1", "title=Signs",
		src).CombinedOutput()
	if err != nil {
		t.Fatalf("build fixture: %v\n%s", err, out)
	}
	return src
}

func TestNormalizeArgsMapEveryTextSubtitleAsMovText(t *testing.T) {
	for _, action := range []Action{ActionRemux, ActionEncode} {
		args := strings.Join(buildFFmpegArgs("in.mkv", "out.mp4", action, 1080, "", []int{2, 3}), " ")
		for _, want := range []string{"-map 0:2", "-map 0:3", "-c:s mov_text"} {
			if !strings.Contains(args, want) {
				t.Errorf("%s: args missing %q: %s", action, want, args)
			}
		}
	}
}

func TestNormalizeArgsWithoutSubtitlesAddNoSubtitleFlags(t *testing.T) {
	for _, action := range []Action{ActionRemux, ActionEncode} {
		args := strings.Join(buildFFmpegArgs("in.mkv", "out.mp4", action, 1080, "", nil), " ")
		if strings.Contains(args, "mov_text") || strings.Contains(args, "-c:s") || strings.Contains(args, "0:2") {
			t.Errorf("%s: a source with no subtitles got subtitle flags: %s", action, args)
		}
	}
}

func TestTextSubtitleIndicesUsesProbeClassification(t *testing.T) {
	pr := &transcode.ProbeResult{EmbeddedSubs: []transcode.EmbeddedSubtitle{
		{Index: 2, Codec: "ass"},
		{Index: 3, Codec: "hdmv_pgs_subtitle", IsImage: true},
		{Index: 4, Codec: "subrip"},
	}}
	got := textSubtitleIndices(pr)
	if len(got) != 2 || got[0] != 2 || got[1] != 4 {
		t.Fatalf("textSubtitleIndices = %v, want [2 4]", got)
	}
	if !hasImageSubtitles(pr) {
		t.Fatal("hasImageSubtitles = false for a source with a PGS track")
	}
	if hasImageSubtitles(&transcode.ProbeResult{EmbeddedSubs: pr.EmbeddedSubs[:1]}) {
		t.Fatal("hasImageSubtitles = true for a text-only source")
	}
}

// Image subtitles cannot go into MP4, so a file that has any is left alone: never
// converted, original untouched (the safe path, TASK-1070).
func TestDecideSkipsFilesWithImageSubtitles(t *testing.T) {
	mkv := func(subs ...transcode.EmbeddedSubtitle) *transcode.ProbeResult {
		return &transcode.ProbeResult{VideoCodec: "h264", AudioCodec: "ac3", Container: "matroska", EmbeddedSubs: subs}
	}
	pgs := transcode.EmbeddedSubtitle{Index: 3, Codec: "hdmv_pgs_subtitle", IsImage: true}
	ass := transcode.EmbeddedSubtitle{Index: 2, Codec: "ass"}

	if got := Decide(mkv(pgs), ".mkv"); got != ActionSkip {
		t.Errorf("image-only subs: Decide = %s, want skip", got)
	}
	if got := Decide(mkv(ass, pgs), ".mkv"); got != ActionSkip {
		t.Errorf("text+image subs: Decide = %s, want skip", got)
	}
	if got := Decide(mkv(ass), ".mkv"); got != ActionRemux {
		t.Errorf("text-only subs: Decide = %s, want remux", got)
	}
	if got := Decide(mkv(), ".mkv"); got != ActionRemux {
		t.Errorf("no subs: Decide = %s, want remux", got)
	}
}

func TestConvertKeepsEveryTextSubtitleWithLanguageAndTitle(t *testing.T) {
	ffmpeg := ffmpegOrSkip(t)
	ffprobe := ffprobeOrSkip(t)
	src := subtitledMKV(t, ffmpeg)

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
			if len(pr.EmbeddedSubs) != 2 {
				t.Fatalf("output has %d subtitle streams, want 2: %+v", len(pr.EmbeddedSubs), pr.EmbeddedSubs)
			}
			for i, want := range []struct{ lang, title string }{{"eng", "Full"}, {"fre", "Signs"}} {
				s := pr.EmbeddedSubs[i]
				if s.Codec != "mov_text" || s.IsImage {
					t.Errorf("subtitle %d codec = %q image=%v, want mov_text text", i+1, s.Codec, s.IsImage)
				}
				if s.Language != want.lang {
					t.Errorf("subtitle %d language = %q, want %q", i+1, s.Language, want.lang)
				}
				if s.Title != want.title {
					t.Errorf("subtitle %d title = %q, want %q", i+1, s.Title, want.title)
				}
			}
		})
	}
}

// A source with no subtitles still converts, with none added.
func TestConvertWithoutSubtitlesStillWorks(t *testing.T) {
	ffmpeg := ffmpegOrSkip(t)
	ffprobe := ffprobeOrSkip(t)
	src := twoAudioMKV(t, ffmpeg)
	out, err := Convert(context.Background(), ffmpeg, ffprobe, src, ActionRemux, 1080)
	if err != nil {
		t.Fatalf("Convert: %v", err)
	}
	pr, err := transcode.NewProber(ffprobe).Probe(context.Background(), out)
	if err != nil {
		t.Fatalf("probe output: %v", err)
	}
	if len(pr.EmbeddedSubs) != 0 {
		t.Fatalf("output gained subtitle streams: %+v", pr.EmbeddedSubs)
	}
}

// The verify step is the last guard before the original is deleted, so it must refuse an
// output that lost a text subtitle track even when ffmpeg exited 0.
func TestVerifyRejectsAnOutputMissingTextSubtitles(t *testing.T) {
	ffmpeg := ffmpegOrSkip(t)
	ffprobe := ffprobeOrSkip(t)
	src := subtitledMKV(t, ffmpeg)

	// This is exactly what the old args produced: video and audio, no subtitles.
	lossy := filepath.Join(t.TempDir(), "no subs.mp4")
	if out, err := exec.Command(ffmpeg, "-nostdin", "-y", "-v", "error", "-i", src,
		"-map", "0:v:0", "-map", "0:a?", "-c:v", "copy", "-c:a", "aac", lossy).CombinedOutput(); err != nil {
		t.Fatalf("build lossy output: %v\n%s", err, out)
	}
	err := verifyOutput(context.Background(), ffprobe, src, lossy)
	if err == nil || !strings.Contains(err.Error(), "subtitle track") {
		t.Fatalf("verifyOutput accepted an output with 0 of 2 text subtitle tracks (err=%v)", err)
	}

	// One of two is still a loss.
	partial := filepath.Join(t.TempDir(), "one sub.mp4")
	if out, err := exec.Command(ffmpeg, "-nostdin", "-y", "-v", "error", "-i", src,
		"-map", "0:v:0", "-map", "0:a?", "-map", "0:s:0", "-c:v", "copy", "-c:a", "aac", "-c:s", "mov_text", partial).CombinedOutput(); err != nil {
		t.Fatalf("build partial output: %v\n%s", err, out)
	}
	if err := verifyOutput(context.Background(), ffprobe, src, partial); err == nil {
		t.Fatal("verifyOutput accepted an output with 1 of 2 text subtitle tracks")
	}
}
