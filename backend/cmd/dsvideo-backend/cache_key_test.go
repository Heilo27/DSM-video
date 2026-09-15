package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Trickplay and embedded-subtitle caches used sanitizeID(itemID) as a directory name.
// sanitizeID maps characters one-for-one and so preserves LENGTH; item IDs derive from
// file paths, and a deep library produces one longer than the 255-byte limit every common
// filesystem places on a single name component. MkdirAll then failed with "file name too
// long" and the feature silently never worked for those items (TASK-753).
//
// The property under test is boundedness, so these assert LENGTH — not merely that the
// function returns something.

func TestCacheKeyIsBoundedRegardlessOfInputLength(t *testing.T) {
	cases := []struct {
		name  string
		input string
	}{
		{"empty", ""},
		{"short", "m1"},
		{"typical path", "/volume1/video/Movies/Inception (2010)/Inception.mkv"},
		{"300 chars", strings.Repeat("a", 300)},
		{"2000 chars", strings.Repeat("deep/path/segment/", 111)},
		{"unicode", strings.Repeat("日本語のタイトル/", 40)},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := cacheKey(c.input)
			// 16 bytes of SHA-256, hex-encoded. Hardcoded, never re-derived from the
			// implementation — a test that recomputes the expression it is checking
			// passes against any change to it.
			if len(got) != 32 {
				t.Errorf("cacheKey(%d-char input) returned %d chars, want exactly 32", len(c.input), len(got))
			}
			if got == "" {
				t.Error("cacheKey returned an empty string, which is not a usable directory name")
			}
		})
	}
}

// The name must be safe to use as a single path component: no separators, no traversal,
// nothing a filesystem or a path join would reinterpret.
func TestCacheKeyIsASingleSafePathComponent(t *testing.T) {
	inputs := []string{
		"../../etc/passwd",
		"/volume1/video/a b c/file.mkv",
		"with\\backslash",
		strings.Repeat("../", 100),
	}
	for _, in := range inputs {
		got := cacheKey(in)
		if strings.ContainsAny(got, `/\`) {
			t.Errorf("cacheKey(%q) = %q contains a path separator", in, got)
		}
		if got == "." || got == ".." || strings.HasPrefix(got, ".") {
			t.Errorf("cacheKey(%q) = %q is a relative-path element", in, got)
		}
		if filepath.Base(got) != got {
			t.Errorf("cacheKey(%q) = %q is not a single path component", in, got)
		}
	}
}

func TestCacheKeyIsStableAndDistinct(t *testing.T) {
	const a = "/volume1/video/Movies/Inception (2010)/Inception.mkv"
	const b = "/volume1/video/Movies/Interstellar (2014)/Interstellar.mkv"

	// Stable: the cache is only useful if the same item resolves to the same directory
	// on every call and every restart.
	if cacheKey(a) != cacheKey(a) {
		t.Error("cacheKey is not deterministic for the same input")
	}
	// Distinct: two items sharing a directory would serve one item's trickplay for the
	// other — a silently wrong result, worse than a miss.
	if cacheKey(a) == cacheKey(b) {
		t.Errorf("distinct items collided on %q", cacheKey(a))
	}
	// Case matters. sanitizeID lowercased, which merged IDs differing only in case;
	// on a case-sensitive volume those are genuinely different files.
	if cacheKey("/Video/A.mkv") == cacheKey("/video/a.mkv") {
		t.Error("cacheKey collided two paths differing only in case")
	}
}

// The end-to-end property the ticket is actually about: a directory named by this key
// can be CREATED for an input that the old scheme could not.
func TestCacheKeyDirectoryIsCreatableForPathologicalID(t *testing.T) {
	root := t.TempDir()
	longID := "/volume1/video/" + strings.Repeat("a-very-long-directory-segment/", 20) + "file.mkv"

	if err := os.MkdirAll(filepath.Join(root, "trickplay", cacheKey(longID)), 0o755); err != nil {
		t.Fatalf("MkdirAll with cacheKey failed for a %d-char item ID: %v", len(longID), err)
	}

	// Demonstrate the failure this replaces, so the test documents the defect rather
	// than just asserting the fix. sanitizeID keeps the length, so this must fail.
	err := os.MkdirAll(filepath.Join(root, "trickplay-old", sanitizeID(longID)), 0o755)
	if err == nil {
		t.Skip("filesystem accepted a >255-byte name component; the original defect " +
			"cannot be demonstrated here, but the cacheKey assertion above still holds")
	}
}
