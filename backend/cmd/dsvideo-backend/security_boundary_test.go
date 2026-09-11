package main

import (
	"database/sql"
	"math"
	"os"
	"path/filepath"
	"testing"
)

// pathWithinMediaRoot is the boundary between a client-influenced path and ffmpeg reading
// arbitrary files off the NAS. It is enforced at playback, trickplay, subtitle extraction,
// session rehydration and (since recently) the WebAPI streaming open — but nothing tested
// it. It is a prefix-string comparison, which is exactly the shape a future
// "simplification" gets subtly wrong.
//
// These call the real method on a real Server, not a reimplementation.

func serverWithRoots(movies, tv, home string) *Server {
	s := &Server{}
	s.cfg.MoviesPath = movies
	s.cfg.TVPath = tv
	s.cfg.HomePath = home
	return s
}

func TestPathWithinMediaRootAcceptsFilesUnderARoot(t *testing.T) {
	s := serverWithRoots("/volume1/video/Movies", "/volume1/video/Shows", "")
	cases := []string{
		"/volume1/video/Movies/Heat (1995).mkv",
		"/volume1/video/Movies/nested/deep/file.mp4",
		"/volume1/video/Shows/Show/S01/E01.mkv",
		// The root itself is inside the root.
		"/volume1/video/Movies",
		// Clean() normalises redundant separators before the comparison.
		"//volume1//video//Movies//a.mkv",
	}
	for _, p := range cases {
		if !s.pathWithinMediaRoot(p) {
			t.Errorf("expected %q to be within a media root", p)
		}
	}
}

// The separator-terminated prefix is the point: without it, "/volume1/video/Movies2"
// passes as a prefix match of "/volume1/video/Movies" and a sibling directory becomes
// readable.
func TestPathWithinMediaRootRejectsPrefixSiblings(t *testing.T) {
	s := serverWithRoots("/volume1/video/Movies", "", "")
	for _, p := range []string{
		"/volume1/video/Movies2/secret.mkv",
		"/volume1/video/Movies-backup/a.mkv",
		"/volume1/video/MoviesOld",
	} {
		if s.pathWithinMediaRoot(p) {
			t.Errorf("%q is a SIBLING of the root, not inside it — must be rejected", p)
		}
	}
}

func TestPathWithinMediaRootRejectsTraversalAndOutsidePaths(t *testing.T) {
	s := serverWithRoots("/volume1/video/Movies", "/volume1/video/Shows", "")
	for _, p := range []string{
		"/etc/passwd",
		"/volume1/video/Movies/../../../etc/passwd",
		"/volume1/video/Movies/../Shows2/x.mkv",
		"../../etc/passwd",
		"",
	} {
		if s.pathWithinMediaRoot(p) {
			t.Errorf("expected %q to be rejected", p)
		}
	}
}

// FAIL CLOSED. With no roots configured — a misconfigured or half-initialised server —
// every path must be refused. Failing open here would serve the entire filesystem.
func TestPathWithinMediaRootFailsClosedWithNoRoots(t *testing.T) {
	s := serverWithRoots("", "", "")
	for _, p := range []string{"/volume1/video/Movies/a.mkv", "/etc/passwd", "/"} {
		if s.pathWithinMediaRoot(p) {
			t.Errorf("no roots configured: %q must be refused (fail closed)", p)
		}
	}
}

// filepath.Clean does NOT resolve symlinks, so a symlink inside a media root still points
// wherever it points. This test documents that limitation rather than asserting a
// guarantee the function does not make — so nobody later reads these tests as proof that
// symlink escapes are handled.
func TestPathWithinMediaRootDoesNotResolveSymlinks(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	s := serverWithRoots(root, "", "")

	link := filepath.Join(root, "escape")
	if err := osSymlink(outside, link); err != nil {
		t.Skipf("symlink unsupported here: %v", err)
	}
	// The LEXICAL path is inside the root, so this returns true even though the target is
	// not. Containment is lexical by design; if that ever needs to change, this test is
	// where the expectation is recorded.
	if !s.pathWithinMediaRoot(filepath.Join(link, "file.mkv")) {
		t.Fatal("expected lexical containment to accept a path under a symlinked directory")
	}
}

// clampStartSeconds bounds the ?start= transcode offset.
//
// The unknown-duration case is the one that mattered: it originally skipped the clamp
// entirely, so an arbitrary value reached ffmpeg's -ss for any item whose probe never read
// a runtime — seeking past EOF and producing an empty playlist the client surfaces as
// "resource unavailable".
func TestClampStartSeconds(t *testing.T) {
	dur := func(v int64) sql.NullInt64 { return sql.NullInt64{Int64: v, Valid: true} }
	unknown := sql.NullInt64{}

	cases := []struct {
		name     string
		raw      string
		duration sql.NullInt64
		want     float64
	}{
		{"absent", "", dur(7200), 0},
		{"unparseable", "abc", dur(7200), 0},
		{"negative", "-5", dur(7200), 0},
		{"zero", "0", dur(7200), 0},
		{"NaN", "NaN", dur(7200), 0},
		{"positive infinity", "Inf", dur(7200), 0},
		{"negative infinity", "-Inf", dur(7200), 0},
		{"in range", "45", dur(7200), 45},
		{"clamped to runtime less a margin", "999999", dur(7200), 7190},
		{"huge float clamped", "1e308", dur(7200), 7190},

		// The bug: with no runtime to bound against, the only safe answer is 0.
		{"unknown duration ignores a huge offset", "1e308", unknown, 0},
		{"unknown duration ignores any offset", "45", unknown, 0},
		{"zero duration ignores any offset", "45", dur(0), 0},

		// A clip shorter than the safety margin can never be started mid-file.
		{"clip shorter than the margin", "5", dur(8), 0},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := clampStartSeconds(c.raw, c.duration); got != c.want {
				t.Errorf("clampStartSeconds(%q, %v) = %v, want %v", c.raw, c.duration, got, c.want)
			}
		})
	}
}

// The result must always be a usable ffmpeg -ss argument: finite, non-negative, and
// strictly inside the media. Asserted as a property so a future edit cannot reintroduce a
// non-finite passthrough for an input this table does not happen to list.
func TestClampStartSecondsAlwaysProducesAUsableOffset(t *testing.T) {
	inputs := []string{"", "abc", "-1", "NaN", "Inf", "-Inf", "1e308", "0.0001", "45", "7200", "99999999"}
	durations := []sql.NullInt64{
		{}, {Int64: 0, Valid: true}, {Int64: 8, Valid: true},
		{Int64: 120, Valid: true}, {Int64: 7200, Valid: true},
	}
	for _, in := range inputs {
		for _, d := range durations {
			got := clampStartSeconds(in, d)
			if got < 0 {
				t.Fatalf("clampStartSeconds(%q, %v) = %v — negative offsets are not valid", in, d, got)
			}
			if isNaN(got) || isInf(got) {
				t.Fatalf("clampStartSeconds(%q, %v) = %v — non-finite reaches ffmpeg -ss", in, d, got)
			}
			if d.Valid && d.Int64 > 0 && got >= float64(d.Int64) {
				t.Fatalf("clampStartSeconds(%q, %v) = %v — at or past the end of the media", in, d, got)
			}
		}
	}
}

func osSymlink(target, link string) error { return os.Symlink(target, link) }
func isNaN(f float64) bool                { return math.IsNaN(f) }
func isInf(f float64) bool                { return math.IsInf(f, 0) }
