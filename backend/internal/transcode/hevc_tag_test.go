package transcode

import "testing"

// Apple requires the hvc1 FourCC for HEVC in MP4/MOV. With hev1 the parameter sets live
// in-band rather than in the sample description, and AVFoundation will not initialise a
// decoder: the file opens, audio plays, and the video renders BLACK with no error.
//
// Found on a real library — 15 of 17 HEVC movies were tagged hev1 and played as
// audio-only on Apple TV (Sleeping Beauty 1959, The Three Musketeers 1993, Rear Window,
// North by Northwest). The probe never captured the tag, so the server saw
// "hevc + aac + mp4" and confidently chose DirectPlay.

func TestHev1HevcIsNotDirectPlayed(t *testing.T) {
	got := DecidePlaybackWithTag("hevc", "aac", "mp4", "hev1")
	if got == DirectPlay {
		t.Fatal("hev1 HEVC must not DirectPlay — Apple renders it as a black screen with audio")
	}
	if got != RemuxOnly {
		t.Fatalf("hev1 should remux (a container relabel, not a re-encode); got %v", got)
	}
}

func TestHvc1HevcStillDirectPlays(t *testing.T) {
	if got := DecidePlaybackWithTag("hevc", "aac", "mp4", "hvc1"); got != DirectPlay {
		t.Fatalf("hvc1 is the Apple-native tag and must still DirectPlay; got %v", got)
	}
}

// Some probes report no tag. Assuming the worst there would needlessly remux files that
// play fine, so an unknown tag is treated as compatible.
func TestUnknownTagIsTreatedAsCompatible(t *testing.T) {
	if got := DecidePlaybackWithTag("hevc", "aac", "mp4", ""); got != DirectPlay {
		t.Fatalf("an absent tag must not force a remux; got %v", got)
	}
}

// The tag check is HEVC-specific. avc1 is correct for H.264 and must be left alone.
func TestH264IsUnaffectedByTagCheck(t *testing.T) {
	if got := DecidePlaybackWithTag("h264", "aac", "mp4", "avc1"); got != DirectPlay {
		t.Fatalf("H.264/avc1 must DirectPlay; got %v", got)
	}
}

// A file that was already going to be transcoded or remuxed for another reason must not
// be downgraded by this rule — the output container is rewritten either way.
func TestAlreadyIncompatibleFileKeepsItsMode(t *testing.T) {
	if got := DecidePlaybackWithTag("hevc", "dts", "mkv", "hev1"); got != RemuxOnly {
		t.Fatalf("mkv+dts already remuxes; got %v", got)
	}
	if got := DecidePlaybackWithTag("vp9", "opus", "webm", ""); got != FullTranscode {
		t.Fatalf("vp9 still needs a full transcode; got %v", got)
	}
}

// The scanner writes items.needs_transcode from needsTranscode(), NOT from
// DecidePlayback*. When those were two separate implementations, the hev1 fix landed in
// one and was silently absent from the other — so every affected file kept its stale
// DirectPlay decision and kept playing as audio-only. This pins them together.
func TestNeedsTranscodeAgreesWithDecision(t *testing.T) {
	cases := []struct {
		name                             string
		video, audio, container, tag     string
		wantNeedsTranscode               bool
	}{
		{"hev1 hevc mp4", "hevc", "aac", "mp4", "hev1", true},
		{"hvc1 hevc mp4", "hevc", "aac", "mp4", "hvc1", false},
		{"h264 mp4", "h264", "aac", "mp4", "avc1", false},
		{"hevc untagged", "hevc", "aac", "mp4", "", false},
		{"mkv dts", "hevc", "dts", "mkv", "hvc1", true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			pr := &ProbeResult{
				VideoCodec: c.video, AudioCodec: c.audio,
				Container: c.container, VideoCodecTag: c.tag,
			}
			if got := needsTranscode(pr); got != c.wantNeedsTranscode {
				t.Fatalf("needsTranscode = %v, want %v", got, c.wantNeedsTranscode)
			}
			// And the two entry points must never disagree.
			viaDecision := DecidePlaybackWithTag(c.video, c.audio, c.container, c.tag) != DirectPlay
			if needsTranscode(pr) != viaDecision {
				t.Fatal("needsTranscode and DecidePlaybackWithTag disagree — the duplication is back")
			}
		})
	}
}
