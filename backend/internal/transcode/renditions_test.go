package transcode

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TASK-982 (FR-061): only the first audio track survived the HLS transcode. Every
// session mapped "-map 0:a:0?", so a second language or a commentary track never
// reached the client, and the output was a single media playlist with no master for
// AVPlayer to build an audio selection group from.

// twoTrackSource is a probe result for an MKV with an AAC main track and an AC-3
// commentary track: one track that can be copied and one that must be encoded.
func twoTrackSource() []AudioStream {
	return []AudioStream{
		{Index: 1, Codec: "aac", Channels: 2, Language: "eng", Default: true},
		{Index: 2, Codec: "ac3", Channels: 6, Language: "eng", Title: "Commentary"},
	}
}

func argValue(args []string, flag string) (string, bool) {
	for i := 0; i+1 < len(args); i++ {
		if args[i] == flag {
			return args[i+1], true
		}
	}
	return "", false
}

func countPair(args []string, flag, value string) int {
	n := 0
	for i := 0; i+1 < len(args); i++ {
		if args[i] == flag && args[i+1] == value {
			n++
		}
	}
	return n
}

func TestMultiAudioArgsMapEveryTrackAndTheVideoOnce(t *testing.T) {
	for _, mode := range []PlaybackMode{RemuxOnly, FullTranscode} {
		g := NewHLSGenerator(HLSConfig{TempDir: t.TempDir(), AudioBitrate: "192k", HWAccel: "off"})
		dir := t.TempDir()
		args := g.buildFFmpegArgs(&HLSSession{Mode: mode, OutputDir: dir, AudioTracks: twoTrackSource()})

		if n := countPair(args, "-map", "0:v:0"); n != 1 {
			t.Errorf("mode %v: video mapped %d times, want exactly once (never one encode per audio track)", mode, n)
		}
		for _, m := range []string{"0:1", "0:2"} {
			if countPair(args, "-map", m) != 1 {
				t.Errorf("mode %v: audio stream %s not mapped once: %q", mode, m, args)
			}
		}
		if countPair(args, "-map", "0:a:0?") != 0 {
			t.Errorf("mode %v: still maps only the first audio track: %q", mode, args)
		}
		if countPair(args, "-c:a:0", "copy") != 1 {
			t.Errorf("mode %v: the AAC track should be copied: %q", mode, args)
		}
		if countPair(args, "-c:a:1", "aac") != 1 || countPair(args, "-ac:a:1", "2") != 1 || countPair(args, "-b:a:1", "192k") != 1 {
			t.Errorf("mode %v: the AC-3 track should be encoded to stereo AAC: %q", mode, args)
		}
		if _, ok := argValue(args, "-c:a"); ok {
			t.Errorf("mode %v: a blanket -c:a would re-encode the copyable track: %q", mode, args)
		}
		vsm, ok := argValue(args, "-var_stream_map")
		want := "v:0,agroup:aud,name:video a:0,agroup:aud,name:audio_0 a:1,agroup:aud,name:audio_1"
		if !ok || vsm != want {
			t.Errorf("mode %v: -var_stream_map = %q, want %q", mode, vsm, want)
		}
		if got := args[len(args)-1]; got != filepath.Join(dir, "%v.m3u8") {
			t.Errorf("mode %v: output = %q, want one playlist per rendition", mode, got)
		}
		if v, _ := argValue(args, "-hls_fmp4_init_filename"); v != "init_%v.mp4" {
			t.Errorf("mode %v: init filename = %q, want a per-rendition init segment", mode, v)
		}
	}
}

// AC4: a title with one audio track (or none) keeps the original output exactly.
func TestSingleAudioArgsUnchanged(t *testing.T) {
	for _, tracks := range [][]AudioStream{nil, twoTrackSource()[:1]} {
		g := NewHLSGenerator(HLSConfig{TempDir: t.TempDir(), AudioBitrate: "192k", HWAccel: "off"})
		dir := t.TempDir()
		args := g.buildFFmpegArgs(&HLSSession{Mode: RemuxOnly, OutputDir: dir, AudioTracks: tracks})
		joined := strings.Join(args, " ")
		for _, want := range []string{"-map 0:v:0 -map 0:a:0? -c:a aac -b:a 192k -ac 2", "-hls_fmp4_init_filename init.mp4"} {
			if !strings.Contains(joined, want) {
				t.Errorf("%d track(s): args lost %q: %s", len(tracks), want, joined)
			}
		}
		if strings.Contains(joined, "-var_stream_map") {
			t.Errorf("%d track(s): single-audio output must not split into renditions: %s", len(tracks), joined)
		}
		if got := args[len(args)-1]; got != filepath.Join(dir, "master.m3u8") {
			t.Errorf("%d track(s): output = %q, want master.m3u8", len(tracks), got)
		}
	}
}

func TestRenditionMasterListsEveryTrack(t *testing.T) {
	m := buildRenditionMaster(twoTrackSource(), 5_000_000)
	lines := strings.Split(strings.TrimSpace(m), "\n")

	var media []string
	for _, l := range lines {
		if strings.HasPrefix(l, "#EXT-X-MEDIA:") {
			media = append(media, l)
		}
	}
	if len(media) != 2 {
		t.Fatalf("want 2 EXT-X-MEDIA lines, got %d:\n%s", len(media), m)
	}
	for i, l := range media {
		for _, want := range []string{"TYPE=AUDIO", `GROUP-ID="aud"`, `LANGUAGE="eng"`, "AUTOSELECT=YES", `URI="` + audioRendition(i) + `.m3u8"`} {
			if !strings.Contains(l, want) {
				t.Errorf("rendition %d lacks %s: %s", i, want, l)
			}
		}
	}
	if !strings.Contains(media[0], "DEFAULT=YES") || !strings.Contains(media[1], "DEFAULT=NO") {
		t.Errorf("exactly the source's default track should be DEFAULT=YES:\n%s", m)
	}
	if !strings.Contains(media[0], `NAME="eng"`) || !strings.Contains(media[1], `NAME="Commentary"`) {
		t.Errorf("names should be the title, else the language:\n%s", m)
	}
	// Copied AAC keeps its channel count; the encoded AC-3 track is stereo.
	if !strings.Contains(media[0], `CHANNELS="2"`) || !strings.Contains(media[1], `CHANNELS="2"`) {
		t.Errorf("CHANNELS should describe what the rendition carries:\n%s", m)
	}
	n := len(lines)
	if lines[n-2] != `#EXT-X-STREAM-INF:BANDWIDTH=5000000,AUDIO="aud"` || lines[n-1] != "video.m3u8" {
		t.Errorf("variant should be the video rendition in the audio group:\n%s", m)
	}
}

func TestRenditionMasterNamesAreUniqueAndOneDefault(t *testing.T) {
	tracks := []AudioStream{
		{Index: 1, Codec: "ac3", Language: "eng"},
		{Index: 2, Codec: "ac3", Language: "eng"},
		{Index: 3, Codec: "aac", Channels: 6, Title: `Dir"ector`, Default: true},
		{Index: 4, Codec: "dts"},
	}
	m := buildRenditionMaster(tracks, 0)
	for _, want := range []string{`NAME="eng"`, `NAME="eng (2)"`, `NAME="Dir'ector"`, `NAME="Track 4"`, `CHANNELS="6"`, "BANDWIDTH=8000000"} {
		if !strings.Contains(m, want) {
			t.Errorf("master lacks %s:\n%s", want, m)
		}
	}
	if c := strings.Count(m, "DEFAULT=YES"); c != 1 {
		t.Errorf("want exactly one DEFAULT=YES, got %d:\n%s", c, m)
	}
	if !strings.Contains(m, `NAME="Dir'ector",DEFAULT=YES`) {
		t.Errorf("the track the source marks default should be DEFAULT=YES:\n%s", m)
	}
	if strings.Contains(m, "LANGUAGE=\"\"") {
		t.Errorf("an untagged track must omit LANGUAGE:\n%s", m)
	}
}

// The master is the "playable" signal for the whole pipeline, so it must not appear
// before every playlist it lists does.
func TestRenditionMasterWaitsForEveryPlaylist(t *testing.T) {
	g := NewHLSGenerator(HLSConfig{TempDir: t.TempDir(), HWAccel: "off"})
	stopSessionsOnCleanup(t, g)
	dir := filepath.Join(g.config.TempDir, "s1")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	g.sessions["s1"] = &HLSSession{SessionID: "s1", OutputDir: dir, AudioTracks: twoTrackSource(), CompletedAt: &now, done: closedChan()}

	write := func(name string) {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("#EXTM3U\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("video.m3u8")
	write("audio_0.m3u8")
	if g.IsReady("s1") {
		t.Fatal("master written while audio_1.m3u8 is missing")
	}
	write("audio_1.m3u8")
	if !g.IsReady("s1") {
		t.Fatal("master not written once every rendition playlist exists")
	}
	b, err := os.ReadFile(filepath.Join(dir, "master.m3u8"))
	if err != nil || strings.Count(string(b), "TYPE=AUDIO") != 2 {
		t.Fatalf("master = %q, %v", b, err)
	}
}

func closedChan() chan struct{} {
	c := make(chan struct{})
	close(c)
	return c
}

// End to end against the real ffmpeg: a two-track MKV becomes a master with two audio
// renditions, each a real AAC playlist, and the video is in its own playlist.
func TestMultiAudioSessionProducesAudioRenditions(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg not installed")
	}
	ffprobe, err := exec.LookPath("ffprobe")
	if err != nil {
		t.Skip("ffprobe not installed")
	}
	src := filepath.Join(t.TempDir(), "two-audio.mkv")
	gen := exec.Command(ffmpeg, "-nostdin", "-y", "-loglevel", "error",
		"-f", "lavfi", "-i", "testsrc=size=320x240:rate=24:duration=8",
		"-f", "lavfi", "-i", "sine=frequency=440:duration=8",
		"-f", "lavfi", "-i", "sine=frequency=880:duration=8",
		"-map", "0", "-map", "1", "-map", "2",
		"-c:v", "libx264", "-preset", "ultrafast", "-g", "24",
		"-c:a:0", "aac", "-c:a:1", "ac3",
		"-metadata:s:a:0", "language=eng",
		"-metadata:s:a:1", "language=fra", "-metadata:s:a:1", "title=Commentary",
		src)
	if out, err := gen.CombinedOutput(); err != nil {
		t.Skipf("cannot build the fixture with this ffmpeg: %v\n%s", err, out)
	}

	// RemuxOnly copies the video; FullTranscode re-encodes it from a seek point, which
	// is the -ss path a resumed or scrubbed session takes.
	for _, tc := range []struct {
		name  string
		mode  PlaybackMode
		start float64
	}{
		{"remux", RemuxOnly, 0},
		{"transcode-from-seek", FullTranscode, 3},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg := DefaultHLSConfig()
			cfg.TempDir = t.TempDir()
			cfg.FFmpegPath = ffmpeg
			cfg.ABRLadder = nil
			cfg.HWAccel = "off"
			cfg.VideoPreset = "ultrafast"
			g := NewHLSGenerator(cfg)
			stopSessionsOnCleanup(t, g)

			ctx := context.Background()
			if _, err := g.StartSession(ctx, "multi", src, tc.mode, 0, nil, tc.start, "owner"); err != nil {
				t.Fatalf("StartSession: %v", err)
			}
			if err := g.WaitForPlaylist(ctx, "multi", 30*time.Second); err != nil {
				t.Fatalf("WaitForPlaylist: %v", err)
			}
			deadline := time.Now().Add(60 * time.Second)
			for {
				st, err := g.Stats("multi")
				if err != nil {
					t.Fatalf("Stats: %v", err)
				}
				if st.Error != "" {
					t.Fatalf("transcode failed: %s", st.Error)
				}
				if st.CompletedAt != nil {
					break
				}
				if time.Now().After(deadline) {
					t.Fatal("transcode did not finish in 60s")
				}
				time.Sleep(100 * time.Millisecond)
			}

			dir := filepath.Join(cfg.TempDir, "multi")
			master, err := os.ReadFile(filepath.Join(dir, "master.m3u8"))
			if err != nil {
				t.Fatal(err)
			}
			if c := strings.Count(string(master), "#EXT-X-MEDIA:TYPE=AUDIO"); c != 2 {
				t.Fatalf("master has %d audio renditions, want 2:\n%s", c, master)
			}
			if !strings.Contains(string(master), `LANGUAGE="fra",NAME="Commentary"`) {
				t.Errorf("the second track lost its language or title:\n%s", master)
			}

			probe := func(name string) string {
				out, err := exec.Command(ffprobe, "-v", "error", "-show_entries", "stream=codec_type,codec_name",
					"-of", "csv=p=0", filepath.Join(dir, name)).Output()
				if err != nil {
					t.Fatalf("ffprobe %s: %v", name, err)
				}
				// An HLS input lists each stream twice (under its program and on its
				// own), so compare the distinct streams.
				seen := map[string]bool{}
				var streams []string
				for _, l := range strings.Split(string(out), "\n") {
					if l = strings.TrimSpace(l); l != "" && !seen[l] {
						seen[l] = true
						streams = append(streams, l)
					}
				}
				return strings.Join(streams, ";")
			}
			if got := probe("video.m3u8"); got != "h264,video" {
				t.Errorf("video.m3u8 streams = %q, want video only", got)
			}
			for _, name := range []string{"audio_0.m3u8", "audio_1.m3u8"} {
				if got := probe(name); got != "aac,audio" {
					t.Errorf("%s streams = %q, want one AAC audio stream", name, got)
				}
			}
		})
	}
}
