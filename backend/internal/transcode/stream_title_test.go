package transcode

import "testing"

// TASK-1073: the ffmpeg 6.1 bundled on the NAS writes a converted track's title only as
// the MP4 handler name, so the probe must read it from there, and must not mistake the
// generic label a muxer writes when no title was set for a title.
func TestStreamTitle(t *testing.T) {
	for _, tc := range []struct {
		name string
		tags map[string]string
		want string
	}{
		{"mkv title", map[string]string{"title": "Commentary"}, "Commentary"},
		{"title wins over name and handler", map[string]string{"title": "A", "name": "B", "handler_name": "C"}, "A"},
		{"mp4 udta name", map[string]string{"name": "Signs", "handler_name": "SubtitleHandler"}, "Signs"},
		{"handler name only", map[string]string{"language": "spa", "handler_name": "Latin_America_CR"}, "Latin_America_CR"},
		{"generic subtitle handler", map[string]string{"handler_name": "SubtitleHandler"}, ""},
		{"generic sound handler", map[string]string{"handler_name": "SoundHandler"}, ""},
		{"generic apple handler", map[string]string{"handler_name": "Apple Sound Media Handler"}, ""},
		{"generic core media", map[string]string{"handler_name": "Core Media Audio"}, ""},
		{"no tags", nil, ""},
		{"blank title falls through", map[string]string{"title": "  ", "handler_name": "CR"}, "CR"},
	} {
		if got := streamTitle(tc.tags); got != tc.want {
			t.Errorf("%s: streamTitle = %q, want %q", tc.name, got, tc.want)
		}
	}
}

func TestStreamDurationSecs(t *testing.T) {
	if got := streamDurationSecs("", map[string]string{"DURATION": "00:24:00.105000000"}); got < 1440.1 || got > 1440.11 {
		t.Errorf("mkv DURATION tag = %v, want 1440.105", got)
	}
	if got := streamDurationSecs("12.5", nil); got != 12.5 {
		t.Errorf("duration field = %v, want 12.5", got)
	}
	if got := streamDurationSecs("", map[string]string{"language": "eng"}); got != 0 {
		t.Errorf("no duration = %v, want 0", got)
	}
}
