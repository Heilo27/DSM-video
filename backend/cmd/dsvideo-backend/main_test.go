package main

import "testing"

// TestValidateOriginalsDir — Worf P2-5: the retention reaper must refuse to run when its
// backup dir is empty, a filesystem root, equal to a media root, or a parent of a media
// root (any of which would delete the user's library). A safe sibling dir passes.
func TestValidateOriginalsDir(t *testing.T) {
	movies := "/volume1/video/Movies"
	tv := "/volume1/video/TV"

	safe := "/volume1/video/_dsvideo_originals"
	if reason := validateOriginalsDir(safe, movies, tv, ""); reason != "" {
		t.Errorf("safe sibling dir rejected: %s", reason)
	}

	cases := map[string]string{
		"":                    "empty",
		"/":                   "filesystem root",
		"/volume1/video/Movies": "equals media root",
		"/volume1/video":      "parent of media root", // parent of both Movies and TV
	}
	for dir, why := range cases {
		if reason := validateOriginalsDir(dir, movies, tv, ""); reason == "" {
			t.Errorf("dir %q (%s) should have been rejected but passed", dir, why)
		}
	}

	// Trailing-slash and uncleaned forms of a media root must still be caught.
	if reason := validateOriginalsDir("/volume1/video/Movies/", movies, tv, ""); reason == "" {
		t.Error("trailing-slash form of a media root should be rejected")
	}

	// A media root NOT under the originals dir, and originals not under it, is fine even
	// if they share a prefix string (e.g. Movies vs Movies2 must not false-match).
	if reason := validateOriginalsDir("/volume1/video/Movies2", movies, tv, ""); reason != "" {
		t.Errorf("sibling with shared name prefix wrongly rejected: %s", reason)
	}
}
