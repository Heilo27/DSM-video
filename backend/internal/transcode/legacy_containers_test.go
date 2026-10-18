package transcode

import "testing"

// TASK-990: the scanner now indexes .wmv .mpg .mpeg .m2ts .mts .flv .vob .3gp. None of
// them is a container the Apple player opens natively, so none may resolve to DirectPlay,
// whatever codecs they carry. formatName is what ffprobe reports for that kind of file.
func TestLegacyContainersNeverDirectPlay(t *testing.T) {
	cases := []struct {
		name, ext, formatName string
	}{
		{"wmv", ".wmv", "asf"},
		{"mpg", ".mpg", "mpeg"},
		{"mpeg", ".mpeg", "mpeg"},
		{"vob", ".vob", "mpeg"},
		{"m2ts", ".m2ts", "mpegts"},
		{"mts", ".mts", "mpegts"},
		{"flv", ".flv", "flv"},
		{"3gp", ".3gp", "mov,mp4,m4a,3gp,3g2,mj2"},
		{"3g2", ".3g2", "mov,mp4,m4a,3gp,3g2,mj2"},
		// TASK-1002: the rest of the formats the bundled ffmpeg can decode. .f4v is
		// ISO-BMFF, so ffprobe reports the same name as an .mp4; the extension is what
		// keeps it off the direct-play path.
		{"rm", ".rm", "rm"},
		{"rmvb", ".rmvb", "rm"},
		{"divx", ".divx", "avi"},
		{"asf", ".asf", "asf"},
		{"ogv", ".ogv", "ogg"},
		{"ogm", ".ogm", "ogg"},
		{"f4v", ".f4v", "mov,mp4,m4a,3gp,3g2,mj2"},
	}
	// The best case for direct play: the codecs the player likes best.
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := &ProbeResult{
				Container:  containerForFile(c.formatName, "/lib/clip"+c.ext),
				VideoCodec: "h264",
				AudioCodec: "aac",
			}
			if got := DecidePlaybackFromProbe(r); got == DirectPlay {
				t.Errorf("%s (container %q) with h264+aac must not DirectPlay", c.ext, r.Container)
			}
			if !needsTranscode(r) {
				t.Errorf("%s: items.needs_transcode would be false", c.ext)
			}
			// Quick-probe fallback (no ffprobe) must agree.
			q := ProbeQuick("/lib/CLIP" + c.ext)
			if !q.NeedsTranscode || DecidePlaybackFromProbe(q) == DirectPlay {
				t.Errorf("%s: ProbeQuick would allow direct play: %+v", c.ext, q)
			}
		})
	}
}

// Real-world codecs for these containers need a re-encode, not a remux.
func TestLegacyContainersWithLegacyCodecsFullTranscode(t *testing.T) {
	for _, v := range []string{"wmv3", "mpeg2", "h263", "vc1"} {
		if got := DecidePlayback(v, "aac", "mpeg"); got != FullTranscode {
			t.Errorf("%s video: got %v, want FullTranscode", v, got)
		}
	}
}

// The container rename is for 3GPP only: ordinary MP4/MOV stay direct-playable.
func TestContainerForFileLeavesMP4Alone(t *testing.T) {
	const f = "mov,mp4,m4a,3gp,3g2,mj2"
	if got := containerForFile(f, "/lib/a.mp4"); got != "mov" {
		t.Errorf(".mp4 container = %q, want mov (unchanged)", got)
	}
	if DecidePlayback("h264", "aac", containerForFile(f, "/lib/a.mov")) != DirectPlay {
		t.Error(".mov h264+aac must still direct play")
	}
}
