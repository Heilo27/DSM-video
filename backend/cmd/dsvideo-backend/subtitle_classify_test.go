package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"dsvideo/backend/internal/transcode"
)

// writeSRT writes an SRT file with n evenly-spaced cues over runtimeSecs and returns
// its path. Used to drive the cue-density heuristic.
func writeSRT(t *testing.T, dir, name string, n int, runtimeSecs float64) string {
	t.Helper()
	var b strings.Builder
	for i := 0; i < n; i++ {
		start := runtimeSecs * float64(i) / float64(n)
		end := start + 1.5
		fmt.Fprintf(&b, "%d\n%s --> %s\nline %d\n\n",
			i+1, srtTS(start), srtTS(end), i+1)
	}
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(b.String()), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func srtTS(secs float64) string {
	h := int(secs) / 3600
	m := (int(secs) % 3600) / 60
	s := int(secs) % 60
	ms := int((secs - float64(int(secs))) * 1000)
	return fmt.Sprintf("%02d:%02d:%02d,%03d", h, m, s, ms)
}

func TestSubtitleCueDensity(t *testing.T) {
	dir := t.TempDir()
	runtime := 3600.0 // 1h

	// Dense full-dialogue: ~12 cues/min baseline → 720 cues → density ~1.0
	full := writeSRT(t, dir, "full.srt", 720, runtime)
	if d, ok := subtitleCueDensity(full, runtime); !ok || d < 0.8 {
		t.Errorf("full sub density = %.3f ok=%v, want >=0.8", d, ok)
	}

	// Sparse forced (translation-only): 20 cues over 1h → density ~0.028 (< 0.15)
	forced := writeSRT(t, dir, "forced.srt", 20, runtime)
	if d, ok := subtitleCueDensity(forced, runtime); !ok || d >= forcedCueDensityThreshold {
		t.Errorf("forced sub density = %.3f ok=%v, want < %.2f", d, ok, forcedCueDensityThreshold)
	}

	// Unknown runtime → not ok (fall back to flags).
	if _, ok := subtitleCueDensity(full, 0); ok {
		t.Errorf("expected ok=false for zero runtime")
	}
	// Missing file → not ok.
	if _, ok := subtitleCueDensity(filepath.Join(dir, "nope.srt"), runtime); ok {
		t.Errorf("expected ok=false for missing file")
	}
}

func TestClassifySubtitleTracks(t *testing.T) {
	dir := t.TempDir()
	runtime := 3600.0

	fullPath := writeSRT(t, dir, "movie.en.srt", 720, runtime)
	sparsePath := writeSRT(t, dir, "movie.de.srt", 15, runtime) // sparse, untagged → density-promoted

	tracks := []transcode.SubtitleTrack{
		{Language: "en", Name: "English", Path: fullPath, Type: "full"},                    // full, audio-lang match, must NOT auto-enable
		{Language: "de", Name: "German", Path: sparsePath, Type: "full"},                   // untagged sparse → promoted to forced, but lang != audio
		{Language: "en", Name: "English (Forced)", Path: "", Forced: true, Type: "forced"}, // flagged forced, lang == audio → AUTO-ENABLE
		{Language: "fr", Name: "French", Type: "image"},                                    // image, out of scope
	}

	classifySubtitleTracks(tracks, runtime, "en")

	if tracks[0].Type != "full" || tracks[0].AutoEnable {
		t.Errorf("track0 full-dialogue: type=%q autoEnable=%v, want full/false", tracks[0].Type, tracks[0].AutoEnable)
	}
	if tracks[1].Type != "forced" || !tracks[1].Forced {
		t.Errorf("track1 sparse untagged should be density-promoted to forced, got type=%q forced=%v", tracks[1].Type, tracks[1].Forced)
	}
	if tracks[1].AutoEnable {
		t.Errorf("track1 de forced must NOT auto-enable (audio is en)")
	}
	if tracks[2].Type != "forced" || !tracks[2].AutoEnable {
		t.Errorf("track2 en forced should auto-enable, got type=%q autoEnable=%v", tracks[2].Type, tracks[2].AutoEnable)
	}
	if tracks[3].Type != "image" || tracks[3].Forced || tracks[3].AutoEnable {
		t.Errorf("track3 image must stay image/false/false, got type=%q forced=%v autoEnable=%v", tracks[3].Type, tracks[3].Forced, tracks[3].AutoEnable)
	}

	// Exactly one auto-enable.
	n := 0
	for _, tr := range tracks {
		if tr.AutoEnable {
			n++
		}
	}
	if n != 1 {
		t.Errorf("expected exactly 1 auto-enable track, got %d", n)
	}
}

func TestClassifyNoAudioLangSkipsAutoEnable(t *testing.T) {
	tracks := []transcode.SubtitleTrack{
		{Language: "en", Forced: true, Type: "forced"},
	}
	classifySubtitleTracks(tracks, 3600, "") // unknown audio lang
	if tracks[0].AutoEnable {
		t.Errorf("no audio lang → no auto-enable, but track auto-enabled")
	}
	if tracks[0].Type != "forced" {
		t.Errorf("forced flag should still classify as forced even without audio lang")
	}
}
