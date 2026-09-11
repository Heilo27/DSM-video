package transcode

import (
	"strings"
	"testing"
)

// ffmpeg can only cut an HLS segment AT a keyframe. libx264 defaults to a 250-frame GOP,
// so `-hls_time 6` on 24fps source silently produced 10.4-SECOND segments — verified by
// running the server's exact argument list:
//
//	without these flags: #EXTINF:10.416667
//	with them:           #EXTINF:6.000000
//
// AVPlayer buffers several segments before it begins playback, so the inflated segment
// length translated directly into ~2.5x the startup latency on a NAS transcoding at
// roughly realtime. Startup is the most-felt metric in the whole pipeline, which is why
// this is pinned by a test rather than left to a comment.

func TestGopArgsForceKeyframesAtSegmentBoundary(t *testing.T) {
	args := gopArgs(6)

	joined := strings.Join(args, " ")
	if !strings.Contains(joined, "-force_key_frames") {
		t.Fatalf("gopArgs must force keyframes; got %v", args)
	}
	// Expressed in TIME (t / n_forced), not frames — correct at any source framerate
	// without probing fps first.
	if !strings.Contains(joined, "expr:gte(t,n_forced*6)") {
		t.Errorf("expected a time-based keyframe expression for a 6s segment; got %q", joined)
	}
	// Scene-change detection would insert unplanned keyframes and fragment segments.
	if !strings.Contains(joined, "-sc_threshold 0") {
		t.Errorf("expected scene-change detection disabled; got %q", joined)
	}
}

// The expression must track the configured segment length, not hardcode 6.
func TestGopArgsTracksSegmentLength(t *testing.T) {
	for _, secs := range []int{2, 4, 6, 10} {
		joined := strings.Join(gopArgs(secs), " ")
		want := "n_forced*" + itoa(secs)
		if !strings.Contains(joined, want) {
			t.Errorf("segment=%ds: expected %q in %q", secs, want, joined)
		}
	}
}

// A zero or negative configured value must fall back to the same 6s default the HLS
// argument builder uses, so the forced-keyframe interval can never disagree with
// -hls_time (which would reintroduce the original bug in a subtler form).
func TestSegmentSecondsOrDefault(t *testing.T) {
	cases := map[int]int{0: 6, -1: 6, 4: 4, 6: 6, 10: 10}
	for in, want := range cases {
		if got := segmentSecondsOrDefault(in); got != want {
			t.Errorf("segmentSecondsOrDefault(%d) = %d, want %d", in, got, want)
		}
	}
}

func itoa(i int) string {
	if i == 0 {
		return "0"
	}
	neg := i < 0
	if neg {
		i = -i
	}
	var b []byte
	for i > 0 {
		b = append([]byte{byte('0' + i%10)}, b...)
		i /= 10
	}
	if neg {
		return "-" + string(b)
	}
	return string(b)
}
