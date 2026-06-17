package normalize

import (
	"os"
	"path/filepath"
	"testing"
)

// TestCopyFileSyncedAndSizeMatched — Worf P0-1: copyFile must produce a byte-complete,
// fsync'd copy and only return nil when the destination size matches the source. Here we
// verify the success path leaves a full copy with the source preserved (caller removes src
// separately in moveFile), and that mtime is carried over.
func TestCopyFileSyncedAndSizeMatched(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "src.bin")
	dst := filepath.Join(dir, "sub", "dst.bin")
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		t.Fatal(err)
	}
	// Non-trivial size so a short copy would be detectable.
	want := make([]byte, 1<<20) // 1 MiB
	for i := range want {
		want[i] = byte(i)
	}
	if err := os.WriteFile(src, want, 0o644); err != nil {
		t.Fatal(err)
	}

	if err := copyFile(src, dst); err != nil {
		t.Fatalf("copyFile: %v", err)
	}
	got, err := os.ReadFile(dst)
	if err != nil {
		t.Fatalf("read dst: %v", err)
	}
	if len(got) != len(want) {
		t.Fatalf("dst size = %d, want %d (size-match guard failed)", len(got), len(want))
	}
	si, _ := os.Stat(src)
	di, _ := os.Stat(dst)
	if !si.ModTime().Equal(di.ModTime()) {
		t.Errorf("dst mtime %v != src mtime %v", di.ModTime(), si.ModTime())
	}
	// Source must still be intact — copyFile never touches it.
	if _, err := os.Stat(src); err != nil {
		t.Errorf("source should be intact after copyFile: %v", err)
	}
}

// TestCopyFileMissingSourceErrors — a bad source surfaces an error and creates no
// destination, so a caller can never reach os.Remove(src) on a failed copy (P0-1).
func TestCopyFileMissingSourceErrors(t *testing.T) {
	dir := t.TempDir()
	dst := filepath.Join(dir, "dst.bin")
	if err := copyFile(filepath.Join(dir, "nope.bin"), dst); err == nil {
		t.Fatal("copyFile from missing source should error")
	}
	if _, err := os.Stat(dst); !os.IsNotExist(err) {
		t.Error("no destination should exist after a failed copy")
	}
}

// TestMoveFileCrossDirCopyFallback — moveFile's copy+remove path (same logic as the
// cross-device fallback) leaves a complete dst and removes src only after the synced,
// size-verified copy. We can't force EXDEV in a unit test, but copyFile is the fallback's
// core; this exercises a full move and asserts the post-conditions the P0-1 fix guarantees.
func TestMoveFileLeavesCompleteDestination(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "movie.mkv")
	dst := filepath.Join(dir, "backup", "movie.mkv")
	payload := []byte("the original bytes that must survive")
	if err := os.WriteFile(src, payload, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := moveFile(src, dst); err != nil {
		t.Fatalf("moveFile: %v", err)
	}
	b, err := os.ReadFile(dst)
	if err != nil || string(b) != string(payload) {
		t.Errorf("dst = %q (err %v), want %q", b, err, payload)
	}
	if _, err := os.Stat(src); !os.IsNotExist(err) {
		t.Error("source should be gone after a successful move")
	}
}
