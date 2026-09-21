package metadata

import "testing"

// TASK-913: a 16:9 rail card asking for ~760px used to round straight up to `original`
// and pull the full-resolution source (measured: an 883KB 2000x3000 file for a card
// drawn 380pt wide). w780 and w1280 are backdrop-only rungs on TMDb; without them the
// ladder topped out at w500.
func TestParseImageSize_BackdropRungs(t *testing.T) {
	for _, tc := range []struct {
		in   string
		want ImageSize
	}{
		{"760", ImageSizeW780},   // the tvOS landscape card — the actual bug
		{"780", ImageSizeW780},   // exact rung
		{"w780", ImageSizeW780},  // the "w" prefix form
		{"800", ImageSizeW1280},  // HomeHero's old request
		{"1280", ImageSizeW1280}, // exact rung
		{"1281", ImageSizeOriginal},
		{"501", ImageSizeW780},
		{"500", ImageSizeW500}, // unchanged: posters must not move
		{"342", ImageSizeW342},
		{"", ImageSizeOriginal},
	} {
		if got := ParseImageSize(tc.in); got != tc.want {
			t.Errorf("ParseImageSize(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

// sizeToWidth feeds GenerateImageID, which is the CACHE KEY. If the new sizes returned
// 0 they would collide with ImageSizeOriginal and one would serve the other's bytes —
// a w780 request handing back a multi-megabyte original, or worse, vice versa.
func TestSizeToWidth_NewRungsDoNotCollideWithOriginal(t *testing.T) {
	if got := sizeToWidth(ImageSizeW780); got != 780 {
		t.Errorf("sizeToWidth(w780) = %d, want 780", got)
	}
	if got := sizeToWidth(ImageSizeW1280); got != 1280 {
		t.Errorf("sizeToWidth(w1280) = %d, want 1280", got)
	}

	seen := map[int]ImageSize{}
	for _, s := range []ImageSize{
		ImageSizeW92, ImageSizeW185, ImageSizeW342,
		ImageSizeW500, ImageSizeW780, ImageSizeW1280, ImageSizeOriginal,
	} {
		w := sizeToWidth(s)
		if prev, dup := seen[w]; dup {
			t.Fatalf("cache-key collision: %q and %q both map to width %d", prev, s, w)
		}
		seen[w] = s
	}
}

// The poster and the backdrop of one item share an id, so only the type keeps their
// cached bytes apart.
func TestGenerateImageID_PosterAndBackdropDiffer(t *testing.T) {
	const path = "/abc123.jpg"
	poster := GenerateImageID(path, ImageTypePoster, 780)
	backdrop := GenerateImageID(path, ImageTypeBackdrop, 780)
	if poster == backdrop {
		t.Fatal("poster and backdrop share a cache key; one will serve the other's bytes")
	}
}

// The URL handed to TMDb must carry the new rung verbatim.
func TestGetImageURL_BackdropRungs(t *testing.T) {
	if got, want := GetImageURL("/x.jpg", ImageSizeW780),
		"https://image.tmdb.org/t/p/w780/x.jpg"; got != want {
		t.Errorf("GetImageURL(w780) = %q, want %q", got, want)
	}
	if got, want := GetImageURL("/x.jpg", ImageSizeW1280),
		"https://image.tmdb.org/t/p/w1280/x.jpg"; got != want {
		t.Errorf("GetImageURL(w1280) = %q, want %q", got, want)
	}
}
