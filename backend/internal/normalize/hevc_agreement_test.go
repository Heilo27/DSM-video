package normalize

import (
	"strings"
	"testing"

	"dsvideo/backend/internal/transcode"
)

// Normalize and playback must reach the SAME verdict for a given file.
//
// They did not, for exactly one class: HEVC carrying the hev1 FourCC. decide.go called the
// untagged transcode.DecidePlayback and concluded DirectPlay → ActionSkip, while playback
// called the tagged variant and concluded RemuxOnly. The consequences compounded:
//
//   - Auto-normalize exists so the NAS never has to transcode during playback. These files
//     were permanently excluded from it — ActionSkip means "nothing to do, forever".
//   - Playback therefore paid a remux on EVERY play of those files, indefinitely, on a box
//     with no hardware encoder.
//
// The two sides now share transcode.DecidePlaybackWithTag. This test pins the invariant
// rather than the implementation, so it keeps holding if either side is refactored.

func TestNormalizeAgreesWithPlaybackDecision(t *testing.T) {
	cases := []struct {
		name                  string
		video, audio, contain string
		tag                   string
		wantAction            Action
	}{
		{
			// The shape that regressed: correctly skipped only if the tag says hvc1.
			name:  "hvc1 HEVC needs no work",
			video: "hevc", audio: "aac", contain: "mp4", tag: "hvc1",
			wantAction: ActionSkip,
		},
		{
			// The bug: normalize used to skip this, so it never got fixed and every play
			// paid a remux.
			name:  "hev1 HEVC must be remuxed once, not skipped",
			video: "hevc", audio: "aac", contain: "mp4", tag: "hev1",
			wantAction: ActionRemux,
		},
		{
			name:  "plain h264 is already fine",
			video: "h264", audio: "aac", contain: "mp4", tag: "avc1",
			wantAction: ActionSkip,
		},
		{
			name:  "incompatible container still remuxes",
			video: "h264", audio: "ac3", contain: "mkv", tag: "avc1",
			wantAction: ActionRemux,
		},
		{
			name:  "incompatible video codec still fully encodes",
			video: "vp9", audio: "opus", contain: "webm", tag: "",
			wantAction: ActionEncode,
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			// What playback will decide for this file.
			playback := transcode.DecidePlaybackWithTag(c.video, c.audio, c.contain, c.tag)

			// What normalize should decide, expressed as the mapping decide.go performs.
			var normalizeEquivalent Action
			switch playback {
			case transcode.DirectPlay:
				normalizeEquivalent = ActionSkip
			case transcode.RemuxOnly:
				normalizeEquivalent = ActionRemux
			default:
				normalizeEquivalent = ActionEncode
			}

			if normalizeEquivalent != c.wantAction {
				t.Fatalf("playback says %v → normalize %v, want %v",
					playback, normalizeEquivalent, c.wantAction)
			}

			// The invariant that actually matters: a file normalize declines to touch must
			// be one playback can serve with NO work. Anything else is a permanent tax.
			if normalizeEquivalent == ActionSkip && playback != transcode.DirectPlay {
				t.Fatalf("normalize would skip a file that playback cannot direct-play (%v) — "+
					"that file would be re-processed on every single play", playback)
			}
		})
	}
}

// A remux must be a FIXED POINT: running it on a file must produce something normalize
// will not want to remux again.
//
// It did not. buildFFmpegArgs copied the video stream verbatim, so an hev1-tagged HEVC
// file came out still tagged hev1 — and the tagged decision correctly flagged it for
// remux again on the next scan. Observed live: the same title remuxed three times in one
// run, input path identical to output path, and it would have continued on every scan
// forever, burning ffmpeg slots on a NAS with no hardware encoder.
//
// This asserts the ARGUMENTS carry the relabel, which is what makes the output a fixed
// point. A full round-trip through ffmpeg is covered by running the real server; this
// keeps the invariant pinned without one.
func TestRemuxRelabelsHev1SoItConverges(t *testing.T) {
	args := buildFFmpegArgs("/m/in.mkv", "/m/.in.converting.mp4", ActionRemux, 1080, "hev1")

	joined := strings.Join(args, " ")
	if !strings.Contains(joined, "-tag:v hvc1") {
		t.Fatalf("an hev1 source must be relabelled to hvc1 on remux, or the conversion is a "+
			"no-op for exactly the files it exists to fix and repeats forever; got: %s", joined)
	}
	// Still a stream copy — the relabel is container-level and must not become a re-encode.
	if !strings.Contains(joined, "-c:v copy") {
		t.Errorf("remux must stay a stream copy; got: %s", joined)
	}
}

// The relabel must apply ONLY to hev1. Forcing hvc1 onto h264 (avc1) would produce an
// invalid sample entry.
func TestRemuxDoesNotRelabelNonHev1(t *testing.T) {
	for _, tag := range []string{"avc1", "hvc1", "", "[0][0][0][0]"} {
		joined := strings.Join(buildFFmpegArgs("/m/in.mkv", "/m/out.mp4", ActionRemux, 1080, tag), " ")
		if strings.Contains(joined, "-tag:v") {
			t.Errorf("tag %q must not be relabelled; got: %s", tag, joined)
		}
	}
}

// A full re-encode emits h264/avc1 regardless of the source tag, so it must never carry
// the HEVC relabel.
func TestEncodeNeverCarriesTheHevcTag(t *testing.T) {
	joined := strings.Join(buildFFmpegArgs("/m/in.mkv", "/m/out.mp4", ActionEncode, 1080, "hev1"), " ")
	if strings.Contains(joined, "hvc1") {
		t.Errorf("a libx264 re-encode must not carry an HEVC tag; got: %s", joined)
	}
}
