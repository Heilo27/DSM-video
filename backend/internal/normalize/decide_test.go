package normalize

import (
	"testing"

	"dsvideo/backend/internal/transcode"
)

// TestDecide covers the codec/container matrix, asserting the normalize Action lines
// up with transcode.DecidePlayback semantics (TASK-755). Already-DirectPlay → Skip;
// H.264/HEVC video in a wrong container/audio → Remux; non-H.264/HEVC video → Encode.
func TestDecide(t *testing.T) {
	cases := []struct {
		name      string
		video     string
		audio     string
		container string
		ext       string
		want      Action
	}{
		// DirectPlay — nothing to do.
		{"mp4 h264 aac", "h264", "aac", "mp4", ".mp4", ActionSkip},
		{"mov hevc aac", "hevc", "aac", "mov", ".mov", ActionSkip},
		{"m4v h264 mp3", "h264", "mp3", "m4v", ".m4v", ActionSkip}, // mp3 is compatible

		// Remux — video OK, container and/or audio wrong.
		{"mkv h264 ac3", "h264", "ac3", "mkv", ".mkv", ActionRemux},
		{"mkv hevc dts", "hevc", "dts", "mkv", ".mkv", ActionRemux},
		{"mp4 h264 ac3", "h264", "ac3", "mp4", ".mp4", ActionRemux}, // container OK, audio wrong
		{"ts h264 aac", "h264", "aac", "ts", ".ts", ActionRemux},    // codecs OK, container wrong
		{"mkv h264 flac", "h264", "flac", "mkv", ".mkv", ActionRemux},

		// Encode — video codec not H.264/HEVC.
		{"webm vp9 opus", "vp9", "opus", "webm", ".webm", ActionEncode},
		{"mp4 av1 aac", "av1", "aac", "mp4", ".mp4", ActionEncode},
		{"avi mpeg4 mp3", "mpeg4", "mp3", "avi", ".avi", ActionEncode},
		{"mkv mpeg2 ac3", "mpeg2", "ac3", "mkv", ".mkv", ActionEncode},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			probe := &transcode.ProbeResult{
				VideoCodec: tc.video,
				AudioCodec: tc.audio,
				Container:  tc.container,
			}
			got := Decide(probe, tc.ext)
			if got != tc.want {
				t.Errorf("Decide(%s/%s/%s) = %v, want %v",
					tc.video, tc.audio, tc.container, got, tc.want)
			}
		})
	}
}

// TestDecideNilProbe — an unreadable/non-video file (nil probe or empty video codec)
// must be skipped, matching convert-library.sh's `[ -z "$vcodec" ] && skip`.
func TestDecideNilProbe(t *testing.T) {
	if got := Decide(nil, ".mkv"); got != ActionSkip {
		t.Errorf("Decide(nil) = %v, want ActionSkip", got)
	}
	if got := Decide(&transcode.ProbeResult{Container: "mkv"}, ".mkv"); got != ActionSkip {
		t.Errorf("Decide(empty video codec) = %v, want ActionSkip", got)
	}
}

// TestDecideContainerFallsBackToExt — when the probe omits a container name, the file
// extension supplies it so the container check still works.
func TestDecideContainerFallsBackToExt(t *testing.T) {
	probe := &transcode.ProbeResult{VideoCodec: "h264", AudioCodec: "aac", Container: ""}
	if got := Decide(probe, ".mkv"); got != ActionRemux {
		t.Errorf("Decide(h264/aac, container from .mkv ext) = %v, want ActionRemux", got)
	}
	if got := Decide(probe, ".mp4"); got != ActionSkip {
		t.Errorf("Decide(h264/aac, container from .mp4 ext) = %v, want ActionSkip", got)
	}
}

func TestActionString(t *testing.T) {
	cases := map[Action]string{ActionSkip: "skip", ActionRemux: "remux", ActionEncode: "encode"}
	for a, want := range cases {
		if got := a.String(); got != want {
			t.Errorf("Action(%d).String() = %q, want %q", a, got, want)
		}
	}
}
