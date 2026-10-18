package transcode

import "testing"

// TASK-997: ProbeQuick is the no-ffprobe fallback. It hardcoded NeedsTranscode per
// extension, and for .ts left it false while the container it reports ("ts") is not a
// direct-play container: the items.needs_transcode flag said "direct" for a file the
// decision engine would never direct play. The flag now comes from the one rule.
func TestProbeQuickTSNeverDirectPlays(t *testing.T) {
	q := ProbeQuick("/lib/Show/S01E01.TS")
	if !q.NeedsTranscode {
		t.Errorf(".ts ProbeQuick.NeedsTranscode = false, want true: %+v", q)
	}
	if DecidePlaybackFromProbe(q) == DirectPlay {
		t.Errorf(".ts must not direct play: %+v", q)
	}
}

// ProbeQuick's flag must be the decision engine's answer for what it inferred, for every
// extension the scanner can hand it. Literal expectations pin the three direct-play
// containers so a rule that says "transcode everything" cannot satisfy the equality alone.
func TestProbeQuickFlagIsTheOneRule(t *testing.T) {
	wantDirect := map[string]bool{".mp4": true, ".m4v": true, ".mov": true}
	exts := []string{
		".mp4", ".m4v", ".mov", ".mkv", ".avi", ".ts", ".webm",
		".wmv", ".mpg", ".mpeg", ".m2ts", ".mts", ".flv", ".vob", ".3gp",
		".rm", ".rmvb", ".divx", ".asf", ".ogv", ".ogm", ".f4v",
	}
	for _, ext := range exts {
		q := ProbeQuick("/lib/clip" + ext)
		if q.NeedsTranscode != needsTranscode(q) {
			t.Errorf("%s: ProbeQuick.NeedsTranscode = %v, but the decision engine says %v for %+v",
				ext, q.NeedsTranscode, needsTranscode(q), q)
		}
		if wantDirect[ext] == q.NeedsTranscode {
			t.Errorf("%s: NeedsTranscode = %v, want %v", ext, q.NeedsTranscode, !wantDirect[ext])
		}
	}
}
