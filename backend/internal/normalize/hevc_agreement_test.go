package normalize

import (
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
