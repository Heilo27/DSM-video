package transcode

import (
	"context"
	"fmt"
	"image"
	_ "image/jpeg" // register JPEG decoder for image.DecodeConfig
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// TrickplayResult describes the generated scrubbing-preview artifacts.
type TrickplayResult struct {
	SpritePath string  // Path to the tiled JPEG sprite sheet
	VTTPath    string  // Path to the WebVTT mapping timestamps → sprite tiles
	Interval   float64 // Seconds between thumbnails
	TileWidth  int     // Width of each thumbnail tile (px)
	TileHeight int     // Height of each thumbnail tile (px)
	Columns    int     // Tiles per row in the sprite
	Count      int     // Total thumbnails generated
}

// TrickplayConfig controls thumbnail extraction. Zero values fall back to defaults.
type TrickplayConfig struct {
	IntervalSecs float64 // Seconds between thumbnails (default 10)
	TileWidth    int     // Thumbnail width in px (default 160; height keeps aspect)
	Columns      int     // Tiles per sprite row (default 10)
	// NicePriority is the OS scheduling nice level for the trickplay ffmpeg pass.
	// TASK-752: trickplay is a background convenience and must never starve live
	// playback for CPU, so the caller passes 19 (lowest possible). 0 = run without
	// a nice wrapper. Mirrors HLSConfig.NicePriority / runFFmpegOnce.
	NicePriority int
}

// GenerateTrickplay produces a sprite sheet + WebVTT for scrubbing previews using a
// single ffmpeg pass (fps + scale + tile filters). durationSecs is used to size the
// VTT cues and bound the tile count. Output files are written under outDir; if both
// already exist they are reused (idempotent). Best-effort: returns an error the
// caller can log and ignore.
func GenerateTrickplay(ctx context.Context, ffmpegPath, videoPath, outDir string, durationSecs float64, cfg TrickplayConfig) (*TrickplayResult, error) {
	if ffmpegPath == "" {
		return nil, fmt.Errorf("ffmpeg not found")
	}
	if durationSecs <= 0 {
		return nil, fmt.Errorf("unknown duration")
	}

	interval := cfg.IntervalSecs
	if interval <= 0 {
		interval = 10
	}
	tileW := cfg.TileWidth
	if tileW <= 0 {
		tileW = 160
	}
	cols := cfg.Columns
	if cols <= 0 {
		cols = 10
	}

	count := int(durationSecs/interval) + 1
	if count < 1 {
		count = 1
	}
	// Cap to keep the sprite a sane size for very long files (e.g. 4h film at 10s
	// = 1440 tiles). 2400 tiles ≈ 6.6h at 10s; beyond that widen the interval.
	const maxTiles = 2400
	if count > maxTiles {
		interval = durationSecs / float64(maxTiles)
		count = maxTiles
	}
	rows := (count + cols - 1) / cols

	spritePath := filepath.Join(outDir, "trickplay.jpg")
	vttPath := filepath.Join(outDir, "trickplay.vtt")

	// Reuse if already generated.
	if fileExists(spritePath) && fileExists(vttPath) {
		tileH := tileW * 9 / 16
		return &TrickplayResult{
			SpritePath: spritePath, VTTPath: vttPath, Interval: interval,
			TileWidth: tileW, TileHeight: tileH, Columns: cols, Count: count,
		}, nil
	}

	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return nil, fmt.Errorf("create trickplay dir: %w", err)
	}

	// fps=1/interval samples one frame per interval; scale fixes tile width (height
	// auto, divisible by 2); tile=COLSxROWS packs them into one image.
	vf := fmt.Sprintf("fps=1/%g,scale=%d:-2,tile=%dx%d", interval, tileW, cols, rows)
	genCtx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()

	ffArgs := []string{
		"-v", "error",
		"-y",
		"-i", videoPath,
		"-vf", vf,
		"-frames:v", "1",
		"-q:v", "5",
		spritePath,
	}
	// TASK-752: run the trickplay ffmpeg at the lowest OS priority so it yields CPU
	// to live-playback transcodes (which run at HLSConfig.NicePriority=10). Mirrors
	// the `nice` wrapper in hls.go runFFmpegOnce. nice<=0 means run unwrapped.
	var cmd *exec.Cmd
	if cfg.NicePriority > 0 {
		niceArgs := append([]string{"-n", fmt.Sprintf("%d", cfg.NicePriority), ffmpegPath}, ffArgs...)
		cmd = exec.CommandContext(genCtx, "nice", niceArgs...)
	} else {
		cmd = exec.CommandContext(genCtx, ffmpegPath, ffArgs...)
	}
	if out, err := cmd.CombinedOutput(); err != nil {
		_ = os.Remove(spritePath)
		return nil, fmt.Errorf("ffmpeg trickplay: %w: %s", err, strings.TrimSpace(string(out)))
	}

	// Derive tile height from the produced sprite so VTT coordinates match exactly.
	tileH := tileW * 9 / 16 // fallback; refined below if probe is cheap
	if h := spriteTileHeight(spritePath, cols, rows); h > 0 {
		tileH = h
	}

	if err := writeTrickplayVTT(vttPath, filepath.Base(spritePath), count, cols, interval, tileW, tileH); err != nil {
		return nil, fmt.Errorf("write trickplay vtt: %w", err)
	}

	return &TrickplayResult{
		SpritePath: spritePath, VTTPath: vttPath, Interval: interval,
		TileWidth: tileW, TileHeight: tileH, Columns: cols, Count: count,
	}, nil
}

// writeTrickplayVTT writes WebVTT cues mapping each interval to a sprite tile via
// the #xywh media-fragment syntax that HTML/AVPlayer-adjacent scrubbers understand.
func writeTrickplayVTT(vttPath, spriteName string, count, cols int, interval float64, tileW, tileH int) error {
	var b strings.Builder
	b.WriteString("WEBVTT\n\n")
	for i := 0; i < count; i++ {
		start := float64(i) * interval
		end := float64(i+1) * interval
		col := i % cols
		row := i / cols
		x := col * tileW
		y := row * tileH
		b.WriteString(fmt.Sprintf("%s --> %s\n", vttTimestamp(start), vttTimestamp(end)))
		b.WriteString(fmt.Sprintf("%s#xywh=%d,%d,%d,%d\n\n", spriteName, x, y, tileW, tileH))
	}
	return os.WriteFile(vttPath, []byte(b.String()), 0o644)
}

func vttTimestamp(secs float64) string {
	if secs < 0 {
		secs = 0
	}
	h := int(secs) / 3600
	m := (int(secs) % 3600) / 60
	s := int(secs) % 60
	ms := int((secs - float64(int(secs))) * 1000)
	return fmt.Sprintf("%02d:%02d:%02d.%03d", h, m, s, ms)
}

func fileExists(p string) bool {
	info, err := os.Stat(p)
	return err == nil && !info.IsDir() && info.Size() > 0
}

// spriteTileHeight estimates per-tile height from the sprite's total height / rows.
// Returns 0 if dimensions can't be read (caller keeps its fallback).
func spriteTileHeight(spritePath string, cols, rows int) int {
	if rows <= 0 {
		return 0
	}
	f, err := os.Open(spritePath)
	if err != nil {
		return 0
	}
	defer f.Close()
	cfg, _, err := image.DecodeConfig(f)
	if err != nil || cfg.Height <= 0 {
		return 0
	}
	return cfg.Height / rows
}
