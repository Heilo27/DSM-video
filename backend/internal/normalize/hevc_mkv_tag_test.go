package normalize

import (
	"strings"
	"testing"
)

// TASK-1033 sibling: an HEVC video copied out of an MKV into an MP4 gets the hev1 sample
// entry from ffmpeg's MP4 muxer (an MKV carries no FourCC, so ffprobe reports an empty or
// "[0][0][0][0]" tag and the source tag says nothing about what the copy will carry).
// Apple refuses hev1, so the remux must relabel it hvc1 exactly as it does for an
// hev1-tagged source.

func TestCopiedStreamTag(t *testing.T) {
	cases := []struct {
		name, codec, tag, want string
	}{
		{"mkv hevc, null tag", "hevc", "[0][0][0][0]", "hev1"},
		{"mkv hevc, empty tag", "hevc", "", "hev1"},
		{"mp4 hevc hev1", "hevc", "hev1", "hev1"},
		{"mp4 hevc hvc1 stays", "hevc", "hvc1", "hvc1"},
		{"dolby vision is not relabelled", "hevc", "dvh1", "dvh1"},
		{"h264 in mkv is never relabelled", "h264", "[0][0][0][0]", "[0][0][0][0]"},
		{"h264 avc1", "h264", "avc1", "avc1"},
	}
	for _, c := range cases {
		if got := copiedStreamTag(c.codec, c.tag); got != c.want {
			t.Errorf("%s: copiedStreamTag(%q, %q) = %q, want %q", c.name, c.codec, c.tag, got, c.want)
		}
	}
}

func TestMkvHevcRemuxIsRelabelledAndH264IsNot(t *testing.T) {
	hevc := strings.Join(buildFFmpegArgs("/m/in.mkv", "/m/out.mp4", ActionRemux, 1080, copiedStreamTag("hevc", "[0][0][0][0]"), nil), " ")
	if !strings.Contains(hevc, "-tag:v hvc1") {
		t.Errorf("MKV HEVC remux must carry -tag:v hvc1; got: %s", hevc)
	}
	h264 := strings.Join(buildFFmpegArgs("/m/in.mkv", "/m/out.mp4", ActionRemux, 1080, copiedStreamTag("h264", "[0][0][0][0]"), nil), " ")
	if strings.Contains(h264, "-tag:v") {
		t.Errorf("MKV h264 remux must not be relabelled; got: %s", h264)
	}
}
