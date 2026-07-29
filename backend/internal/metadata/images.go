package metadata

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// maxImageBytes caps the size of a single downloaded image written to the cache.
// TASK-823: the image io.Copy was unbounded — a misbehaving or compromised upstream
// (even the trusted TMDb CDN) could fill the NAS image-cache disk. TMDb "original"
// posters/backdrops are a few MB at most; 32 MiB is a generous ceiling that never
// clips a legitimate image but stops a runaway body.
const maxImageBytes = 32 << 20 // 32 MiB

// download represents an in-flight image download so that waiters can observe its
// actual outcome (path + error), not merely that it finished.
type download struct {
	done chan struct{}
	path string
	err  error
}

// ImageCache handles caching of images from external sources.
type ImageCache struct {
	cacheDir   string
	httpClient *http.Client

	mu       sync.RWMutex
	inFlight map[string]*download // Prevent duplicate downloads
}

// NewImageCache creates a new image cache.
func NewImageCache(cacheDir string) *ImageCache {
	if cacheDir == "" {
		cacheDir = filepath.Join(os.TempDir(), "dsvideo_images")
	}
	os.MkdirAll(cacheDir, 0755)

	return &ImageCache{
		cacheDir: cacheDir,
		httpClient: &http.Client{
			Timeout: 30 * time.Second,
		},
		inFlight: make(map[string]*download),
	}
}

// ImageType represents the type of image.
type ImageType string

const (
	ImageTypePoster   ImageType = "poster"
	ImageTypeBackdrop ImageType = "backdrop"
	ImageTypeStill    ImageType = "still"
	ImageTypeProfile  ImageType = "profile"
)

// ImageRef is a reference to a cached or external image.
type ImageRef struct {
	ID          string    // Unique identifier for the image
	Type        ImageType // poster, backdrop, etc.
	TMDbPath    string    // TMDb image path (e.g., /abc123.jpg)
	CachedPath  string    // Local cache path
	SourceURL   string    // Full URL to original image
	Width       int       // Requested width (0 = original)
	CachedAt    time.Time // When the image was cached
}

// GenerateImageID creates a unique ID for an image based on its source.
func GenerateImageID(tmdbPath string, imageType ImageType, width int) string {
	data := fmt.Sprintf("%s:%s:%d", tmdbPath, imageType, width)
	hash := sha256.Sum256([]byte(data))
	return hex.EncodeToString(hash[:8]) // 16 char hex ID
}

// GetCachedImage returns a cached image if available.
func (c *ImageCache) GetCachedImage(imageID string) (string, bool) {
	// Check for various extensions
	for _, ext := range []string{".jpg", ".png", ".webp"} {
		path := filepath.Join(c.cacheDir, imageID+ext)
		if _, err := os.Stat(path); err == nil {
			return path, true
		}
	}
	return "", false
}

// CacheImage downloads and caches an image from a URL.
func (c *ImageCache) CacheImage(ctx context.Context, imageID, sourceURL string) (string, error) {
	// Check if already cached
	if path, ok := c.GetCachedImage(imageID); ok {
		return path, nil
	}

	// Check if download is already in progress
	c.mu.Lock()
	if dl, ok := c.inFlight[imageID]; ok {
		c.mu.Unlock()
		// Wait for the other download to complete, then adopt its outcome.
		select {
		case <-dl.done:
			if dl.err != nil {
				// TASK-824: surface the real failure instead of the misleading
				// "download completed but image not found" — the download did not
				// complete, it failed.
				return "", fmt.Errorf("shared image download failed: %w", dl.err)
			}
			return dl.path, nil
		case <-ctx.Done():
			return "", ctx.Err()
		}
	}

	// Mark download as in progress
	dl := &download{done: make(chan struct{})}
	c.inFlight[imageID] = dl
	c.mu.Unlock()

	// Record the outcome on dl so waiters observe the real path/error, then release.
	cachePath, err := c.downloadImage(ctx, imageID, sourceURL)
	c.mu.Lock()
	dl.path, dl.err = cachePath, err
	delete(c.inFlight, imageID)
	close(dl.done)
	c.mu.Unlock()
	return cachePath, err
}

// downloadImage performs the actual HTTP fetch and cache write for CacheImage.
func (c *ImageCache) downloadImage(ctx context.Context, imageID, sourceURL string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, sourceURL, nil)
	if err != nil {
		return "", fmt.Errorf("create request: %w", err)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("download image: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("download failed: %d", resp.StatusCode)
	}

	// Determine extension from content type
	ext := ".jpg"
	switch resp.Header.Get("Content-Type") {
	case "image/png":
		ext = ".png"
	case "image/webp":
		ext = ".webp"
	}

	// Save to cache
	cachePath := filepath.Join(c.cacheDir, imageID+ext)
	f, err := os.Create(cachePath)
	if err != nil {
		return "", fmt.Errorf("create cache file: %w", err)
	}
	// TASK-823: bound the copy. LimitReader caps at maxImageBytes+1 so we can
	// detect (and reject) an oversized body rather than silently truncating it.
	limited := io.LimitReader(resp.Body, maxImageBytes+1)
	n, err := io.Copy(f, limited)
	if err != nil {
		f.Close()
		os.Remove(cachePath) // Clean up on error
		return "", fmt.Errorf("write cache file: %w", err)
	}
	if n > maxImageBytes {
		f.Close()
		os.Remove(cachePath)
		return "", fmt.Errorf("image exceeds %d byte cap", maxImageBytes)
	}
	if closeErr := f.Close(); closeErr != nil {
		os.Remove(cachePath) // Clean up partial file on flush/close failure
		return "", closeErr
	}

	return cachePath, nil
}

// CacheTMDbImage downloads and caches a TMDb image.
func (c *ImageCache) CacheTMDbImage(ctx context.Context, tmdbPath string, imageType ImageType, size ImageSize) (string, error) {
	if tmdbPath == "" {
		return "", fmt.Errorf("empty image path")
	}

	imageID := GenerateImageID(tmdbPath, imageType, sizeToWidth(size))
	sourceURL := GetImageURL(tmdbPath, size)

	return c.CacheImage(ctx, imageID, sourceURL)
}

// GetOrCacheTMDbImage returns a cached image or downloads it.
func (c *ImageCache) GetOrCacheTMDbImage(ctx context.Context, tmdbPath string, imageType ImageType, size ImageSize) (string, error) {
	if tmdbPath == "" {
		return "", fmt.Errorf("empty image path")
	}

	imageID := GenerateImageID(tmdbPath, imageType, sizeToWidth(size))

	// Check cache first
	if path, ok := c.GetCachedImage(imageID); ok {
		return path, nil
	}

	// Download and cache
	return c.CacheTMDbImage(ctx, tmdbPath, imageType, size)
}

// sizeToWidth converts ImageSize to width for ID generation.
func sizeToWidth(size ImageSize) int {
	switch size {
	case ImageSizeW92:
		return 92
	case ImageSizeW185:
		return 185
	case ImageSizeW342:
		return 342
	case ImageSizeW500:
		return 500
	case ImageSizeOriginal:
		return 0
	default:
		return 0
	}
}

// ParseImageSize parses a width string to ImageSize.
func ParseImageSize(width string) ImageSize {
	w := strings.TrimPrefix(strings.ToLower(width), "w")
	switch w {
	case "92":
		return ImageSizeW92
	case "185":
		return ImageSizeW185
	case "342":
		return ImageSizeW342
	case "500":
		return ImageSizeW500
	case "original", "":
		return ImageSizeOriginal
	default:
		// Parse as int and find closest
		var n int
		fmt.Sscanf(w, "%d", &n)
		switch {
		case n <= 92:
			return ImageSizeW92
		case n <= 185:
			return ImageSizeW185
		case n <= 342:
			return ImageSizeW342
		case n <= 500:
			return ImageSizeW500
		default:
			return ImageSizeOriginal
		}
	}
}

// CleanupOldImages removes images older than the specified duration.
func (c *ImageCache) CleanupOldImages(maxAge time.Duration) (int, error) {
	entries, err := os.ReadDir(c.cacheDir)
	if err != nil {
		return 0, err
	}

	count := 0
	cutoff := time.Now().Add(-maxAge)

	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}

		info, err := entry.Info()
		if err != nil {
			continue
		}

		if info.ModTime().Before(cutoff) {
			path := filepath.Join(c.cacheDir, entry.Name())
			if err := os.Remove(path); err == nil {
				count++
			}
		}
	}

	return count, nil
}

// CacheSize returns the total size of cached images in bytes.
func (c *ImageCache) CacheSize() (int64, int) {
	entries, err := os.ReadDir(c.cacheDir)
	if err != nil {
		return 0, 0
	}

	var totalSize int64
	count := 0

	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}

		info, err := entry.Info()
		if err != nil {
			continue
		}

		totalSize += info.Size()
		count++
	}

	return totalSize, count
}

// CacheDir returns the cache directory path.
func (c *ImageCache) CacheDir() string {
	return c.cacheDir
}
