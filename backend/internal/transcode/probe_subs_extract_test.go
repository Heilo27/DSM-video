package transcode

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

// TASK-1071: a failed single-pass extraction leaves no partial or half-published output.
func TestExtractEmbeddedSubtitlesFailureLeavesNothing(t *testing.T) {
	dir := t.TempDir()
	ffmpeg := filepath.Join(dir, "ffmpeg")
	// Writes the first output, then fails: the realistic "one stream would not convert".
	script := "#!/bin/sh\nfor a in \"$@\"; do case \"$a\" in *.part) echo x > \"$a\"; break;; esac; done\nexit 1\n"
	if err := os.WriteFile(ffmpeg, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(dir, "cache")
	err := ExtractEmbeddedSubtitles(context.Background(), ffmpeg, "in.mkv", []SubtitleExtraction{
		{StreamIndex: 2, DestPath: filepath.Join(out, "stream_2.srt")},
		{StreamIndex: 3, DestPath: filepath.Join(out, "stream_3.srt")},
	})
	if err == nil {
		t.Fatal("expected an error from a failing ffmpeg")
	}
	entries, _ := os.ReadDir(out)
	if len(entries) != 0 {
		t.Errorf("failure left files behind: %v", entries)
	}
}
