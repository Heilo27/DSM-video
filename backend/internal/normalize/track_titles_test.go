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

// TASK-1073 (FR-063): a converted file's audio and subtitle tracks keep their titles, so
// two tracks in the same language stay distinguishable. The ffmpeg 6.1 on the NAS keeps
// only the language unless the title is set explicitly (as handler_name).

func TestTitleMetadataArgsSetTitleAndHandlerNameForEveryTitledTrack(t *testing.T) {
	pr := &transcode.ProbeResult{
		AudioStreams: []transcode.AudioStream{{Index: 1, Title: ""}, {Index: 2, Title: "Commentary"}},
		EmbeddedSubs: []transcode.EmbeddedSubtitle{
			{Index: 3, Title: "Latin_America_CR"},
			{Index: 4, IsImage: true, Title: "PGS"}, // not carried, must not shift numbering
			{Index: 5, Title: "CR"},
			{Index: 6},
		},
	}
	got := strings.Join(titleMetadataArgs(pr), " ")
	for _, want := range []string{
		"-metadata:s:a:1 title=Commentary", "-metadata:s:a:1 handler_name=Commentary",
		"-metadata:s:s:0 title=Latin_America_CR", "-metadata:s:s:0 handler_name=Latin_America_CR",
		"-metadata:s:s:1 title=CR", "-metadata:s:s:1 handler_name=CR",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("args missing %q: %s", want, got)
		}
	}
	for _, bad := range []string{"s:a:0", "s:s:2", "s:s:3", "PGS"} {
		if strings.Contains(got, bad) {
			t.Errorf("args contain %q for an untitled/uncarried track: %s", bad, got)
		}
	}
}

func TestBuildArgsPlaceTitleMetadataBeforeOutputPath(t *testing.T) {
	for _, action := range []Action{ActionRemux, ActionEncode} {
		args := buildFFmpegArgs("in.mkv", "out.mp4", action, 1080, "", []int{2}, "-metadata:s:s:0", "title=X")
		if args[len(args)-1] != "out.mp4" {
			t.Errorf("%s: output path is not last: %v", action, args)
		}
		if !strings.Contains(strings.Join(args, " "), "-metadata:s:s:0 title=X") {
			t.Errorf("%s: title metadata missing: %v", action, args)
		}
	}
}

// Two Spanish tracks, one Chinese pair and a titled second audio track survive a real
// conversion with their titles, and the probe reads them back.
func TestConvertKeepsTitlesOfSameLanguageTracks(t *testing.T) {
	ffmpeg := ffmpegOrSkip(t)
	ffprobe := ffprobeOrSkip(t)
	dir := t.TempDir()
	var srtArgs, maps []string
	srtArgs = append(srtArgs, "-f", "lavfi", "-i", "testsrc=size=320x240:rate=24:duration=3",
		"-f", "lavfi", "-i", "sine=frequency=440:duration=3",
		"-f", "lavfi", "-i", "sine=frequency=660:duration=3")
	maps = append(maps, "-map", "0:v", "-map", "1:a", "-map", "2:a")
	type sub struct{ lang, title string }
	subs := []sub{{"spa", "Latin_America_CR"}, {"spa", "CR"}, {"chi", "Simplified"}, {"chi", "Traditional"}}
	for i := range subs {
		f := filepath.Join(dir, "s"+string(rune('a'+i))+".srt")
		if err := os.WriteFile(f, []byte(testSRT), 0o644); err != nil {
			t.Fatal(err)
		}
		srtArgs = append(srtArgs, "-i", f)
		maps = append(maps, "-map", string(rune('3'+i))+":s")
	}
	meta := []string{"-metadata:s:a:0", "language=jpn", "-metadata:s:a:0", "title=Main",
		"-metadata:s:a:1", "language=eng", "-metadata:s:a:1", "title=Commentary"}
	for i, s := range subs {
		n := string(rune('0' + i))
		meta = append(meta, "-metadata:s:s:"+n, "language="+s.lang, "-metadata:s:s:"+n, "title="+s.title)
	}
	src := filepath.Join(dir, "dupes.mkv")
	args := append([]string{"-nostdin", "-y", "-v", "error"}, srtArgs...)
	args = append(args, maps...)
	args = append(args, "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac", "-c:s", "srt")
	args = append(args, meta...)
	args = append(args, src)
	if out, err := exec.Command(ffmpeg, args...).CombinedOutput(); err != nil {
		t.Fatalf("build fixture: %v\n%s", err, out)
	}

	out, err := Convert(context.Background(), ffmpeg, ffprobe, src, ActionRemux, 1080)
	if err != nil {
		t.Fatalf("Convert: %v", err)
	}
	pr, err := transcode.NewProber(ffprobe).Probe(context.Background(), out)
	if err != nil {
		t.Fatal(err)
	}
	if len(pr.EmbeddedSubs) != len(subs) {
		t.Fatalf("output has %d subtitle tracks, want %d", len(pr.EmbeddedSubs), len(subs))
	}
	for i, want := range subs {
		if got := pr.EmbeddedSubs[i]; got.Language != want.lang || got.Title != want.title {
			t.Errorf("subtitle %d = %s/%q, want %s/%q", i, got.Language, got.Title, want.lang, want.title)
		}
	}
	if len(pr.AudioStreams) != 2 || pr.AudioStreams[0].Title != "Main" || pr.AudioStreams[1].Title != "Commentary" {
		t.Errorf("audio titles = %+v, want Main, Commentary", pr.AudioStreams)
	}
}
