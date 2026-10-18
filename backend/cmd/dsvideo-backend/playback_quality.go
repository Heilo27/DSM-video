package main

// The ?quality= vocabulary of GET /api/v1/items/{id}/playback.
//
// This map is the single home for it. The web player, the iOS app and the tvOS app all send
// these exact strings (docs/api/DSVideoBackendAPI.md documents them), and
// web_quality_vocab_test.go fails if the embedded web page offers anything else.
//
// Why it matters: handlePlayback treats an unrecognised value as "no cap", with no error, so
// a client that sends the wrong spelling does not fail, it silently gets Auto. The web
// player once offered "1080" (no "p"), so its whole quality menu did nothing (TASK-1031).
var qualityHeights = map[string]int{
	"1080p": 1080,
	"720p":  720,
	"480p":  480,
}

// maxHeightForQuality maps a ?quality= value to the maximum output height for a transcode.
// 0 means no cap: that is what "auto", an empty value and any unrecognised value mean.
func maxHeightForQuality(quality string) int {
	return qualityHeights[quality]
}
