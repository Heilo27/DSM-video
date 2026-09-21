package main

import (
	"testing"

	"dsvideo/backend/internal/metadata"
)

// TASK-913. The reported symptom was wide tvOS rail cards cropping a portrait poster
// onto an actor's torso: poster and backdrop share one id, and nothing asked for the
// backdrop.
func TestSelectItemImage(t *testing.T) {
	const poster = "/poster.jpg"
	const backdrop = "/backdrop.jpg"

	for _, tc := range []struct {
		name             string
		poster, backdrop string
		wantType         string
		expPath          string
		expKind          metadata.ImageType
		expOK            bool
	}{
		{
			name:   "backdrop requested and present — the fix",
			poster: poster, backdrop: backdrop, wantType: "backdrop",
			expPath: backdrop, expKind: metadata.ImageTypeBackdrop, expOK: true,
		},
		{
			name:   "no type requested still defaults to poster",
			poster: poster, backdrop: backdrop, wantType: "",
			expPath: poster, expKind: metadata.ImageTypePoster, expOK: true,
		},
		{
			name:   "explicit poster wins over a present backdrop",
			poster: poster, backdrop: backdrop, wantType: "poster",
			expPath: poster, expKind: metadata.ImageTypePoster, expOK: true,
		},
		{
			// The empty-string defect. sql.NullString.Valid is true for '', so the old
			// code picked backdrop_path='' and asked TMDb for the empty path — a 404 on
			// an item whose poster was sitting right there.
			name:   "backdrop requested but stored empty — falls back, does not 404",
			poster: poster, backdrop: "", wantType: "backdrop",
			expPath: poster, expKind: metadata.ImageTypePoster, expOK: true,
		},
		{
			name:   "poster empty, backdrop present — serves the backdrop",
			poster: "", backdrop: backdrop, wantType: "",
			expPath: backdrop, expKind: metadata.ImageTypeBackdrop, expOK: true,
		},
		{
			name: "neither present", poster: "", backdrop: "", wantType: "backdrop",
			expPath: "", expKind: "", expOK: false,
		},
		{
			name:   "unknown type behaves as poster",
			poster: poster, backdrop: backdrop, wantType: "still",
			expPath: poster, expKind: metadata.ImageTypePoster, expOK: true,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path, kind, ok := selectItemImage(tc.poster, tc.backdrop, tc.wantType)
			if ok != tc.expOK {
				t.Fatalf("ok = %v, want %v", ok, tc.expOK)
			}
			if path != tc.expPath {
				t.Errorf("path = %q, want %q", path, tc.expPath)
			}
			if kind != tc.expKind {
				t.Errorf("kind = %q, want %q", kind, tc.expKind)
			}
		})
	}
}

// A served path must never be empty when ok is true — that is the exact condition that
// made GetOrCacheTMDbImage fail with "empty image path".
func TestSelectItemImage_NeverReturnsEmptyPathWhenOK(t *testing.T) {
	values := []string{"", "/a.jpg"}
	types := []string{"", "poster", "backdrop", "garbage"}
	for _, p := range values {
		for _, b := range values {
			for _, ty := range types {
				if path, _, ok := selectItemImage(p, b, ty); ok && path == "" {
					t.Fatalf("poster=%q backdrop=%q type=%q returned ok with an empty path", p, b, ty)
				}
			}
		}
	}
}
