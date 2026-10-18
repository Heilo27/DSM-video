package transcode

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TASK-1056: the normalize worker gave up on a DS9 episode with only
// "ffprobe failed: exit status 1" in the log, because Probe ran ffprobe with
// -v quiet and threw stderr away. A refused file must surface ffprobe's reason.
func TestProbe_FailureCarriesFFprobeReason(t *testing.T) {
	dir := t.TempDir()
	ffprobe := filepath.Join(dir, "ffprobe")
	// Behaves like ffprobe -v error on an unreadable file: reason on stderr, exit 1.
	// Under -v quiet real ffprobe prints nothing, so the fake stays silent then too.
	script := "#!/bin/sh\n" +
		"for a in \"$@\"; do [ \"$a\" = quiet ] && exit 1; done\n" +
		"echo \"$(eval echo \\${$#}): Invalid data found when processing input\" >&2\n" +
		"exit 1\n"
	if err := os.WriteFile(ffprobe, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	src := filepath.Join(dir, "Indiscretion.mkv")
	if err := os.WriteFile(src, []byte("not a matroska file"), 0o644); err != nil {
		t.Fatal(err)
	}

	_, err := (&Prober{FFprobePath: ffprobe}).Probe(context.Background(), src)
	if err == nil {
		t.Fatal("Probe succeeded on a file ffprobe refused")
	}
	if !strings.Contains(err.Error(), "Invalid data found when processing input") {
		t.Fatalf("Probe error lost ffprobe's reason: %v", err)
	}
}

func TestStderrTail(t *testing.T) {
	cases := map[string]string{
		"":                       "",
		"\n\n":                   "",
		"one\n":                  "one",
		"warn: x\nfatal: y\n\n":  "fatal: y",
		strings.Repeat("a", 400): strings.Repeat("a", 300) + "...",
	}
	for in, want := range cases {
		if got := stderrTail([]byte(in)); got != want {
			t.Errorf("stderrTail(%q) = %q, want %q", in, got, want)
		}
	}
}
