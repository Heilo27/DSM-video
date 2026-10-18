package metadata

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// maxImageBytes caps the size of a single downloaded image written to the cache.
// TASK-823: the image io.Copy was unbounded — a misbehaving or compromised upstream
// (even the trusted TMDb CDN) could fill the NAS image-cache disk. TMDb "original"
// posters/backdrops are a few MB at most; 32 MiB is a generous ceiling that never
// clips a legitimate image but stops a runaway body.
const maxImageBytes = 32 << 20 // 32 MiB

// DefaultImageCacheMaxBytes is the size the on-disk image cache is held under when the
// operator sets nothing (FR-150). The cache used to grow forever; cast photos (a dozen per
// title) would have made that a real disk-fill risk on a NAS. 1 GiB holds roughly the
// poster, backdrop and cast sets of a several-thousand-title library at the sizes the clients
// ask for, and is small next to the media it sits beside. DSVIDEO_IMAGE_CACHE_MAX_MB
// overrides it; 0 turns eviction off.
const DefaultImageCacheMaxBytes int64 = 1 << 30

const (
	// touchInterval is how stale a file's mtime may get before a cache hit refreshes it.
	// mtime is the recency signal for eviction, and refreshing at most once an hour keeps a
	// hit a single stat instead of a metadata write on every poster scroll.
	touchInterval = time.Hour
	// evictLowWater is the fraction of the cap a sweep evicts down to, so a cache sitting at
	// the cap is not re-swept after every download.
	evictLowWater = 0.9
	// sweepEveryFraction: a background sweep is requested once this fraction of the cap has
	// been written since the last one (1/20 = 5%). A download is therefore a counter add,
	// not a directory scan.
	sweepEveryFraction = 20
	// defaultEvictGrace keeps a sweep off files written in the last minutes: a download
	// writes its file in place, and removing it mid-write would hand the caller a path that
	// no longer exists.
	defaultEvictGrace = 2 * time.Minute
)

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

	// Size-capped eviction (FR-150). maxBytes <= 0 means unlimited.
	maxBytes    atomic.Int64
	evictGrace  time.Duration // files newer than this are never evicted
	sweeping    atomic.Bool   // single-flight guard for background sweeps
	sinceSweep  atomic.Int64  // bytes written since the last sweep was requested
	sweepNeeded func()        // test hook: replaces the background goroutine launch when non-nil
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
		inFlight:   make(map[string]*download),
		evictGrace: defaultEvictGrace,
	}
}

// SetMaxBytes sets the size the cache is held under; n <= 0 disables eviction.
func (c *ImageCache) SetMaxBytes(n int64) { c.maxBytes.Store(n) }

// MaxBytes returns the configured cap (0 = unlimited).
func (c *ImageCache) MaxBytes() int64 {
	if n := c.maxBytes.Load(); n > 0 {
		return n
	}
	return 0
}

// isCacheFile reports whether name is a file this cache wrote; eviction touches nothing else
// in the directory.
func isCacheFile(name string) bool {
	switch strings.ToLower(filepath.Ext(name)) {
	case ".jpg", ".png", ".webp":
		return true
	}
	return false
}

// EvictToCap removes the least recently used files (oldest mtime first) until the cache is
// at or under evictLowWater of its cap, and reports how many files and bytes went. A cache
// already under the cap costs one directory read. Files younger than evictGrace are kept, so
// an in-progress download is never deleted out from under its writer.
func (c *ImageCache) EvictToCap() (removed int, freed int64, err error) {
	limit := c.MaxBytes()
	if limit <= 0 {
		return 0, 0, nil
	}
	entries, err := os.ReadDir(c.cacheDir)
	if err != nil {
		return 0, 0, fmt.Errorf("read image cache dir: %w", err)
	}
	type cached struct {
		path  string
		size  int64
		mtime time.Time
	}
	files := make([]cached, 0, len(entries))
	var total int64
	for _, e := range entries {
		if e.IsDir() || !isCacheFile(e.Name()) {
			continue
		}
		info, ierr := e.Info()
		if ierr != nil {
			continue // vanished between ReadDir and Info: nothing to count
		}
		total += info.Size()
		files = append(files, cached{filepath.Join(c.cacheDir, e.Name()), info.Size(), info.ModTime()})
	}
	if total <= limit {
		return 0, 0, nil
	}
	sort.Slice(files, func(i, j int) bool { return files[i].mtime.Before(files[j].mtime) })
	target := int64(float64(limit) * evictLowWater)
	youngest := time.Now().Add(-c.evictGrace)
	var firstErr error
	for _, f := range files {
		if total <= target {
			break
		}
		if f.mtime.After(youngest) {
			break // sorted oldest first, so every later file is younger still
		}
		if rerr := os.Remove(f.path); rerr != nil {
			if !os.IsNotExist(rerr) && firstErr == nil {
				firstErr = fmt.Errorf("evict %s: %w", filepath.Base(f.path), rerr)
			}
			if !os.IsNotExist(rerr) {
				continue
			}
		}
		total -= f.size
		freed += f.size
		removed++
	}
	return removed, freed, firstErr
}

// noteWrite records that n bytes were just cached and, once enough has accumulated since
// the last sweep, starts one in the background. At most one sweep runs at a time.
func (c *ImageCache) noteWrite(n int64) {
	limit := c.MaxBytes()
	if limit <= 0 {
		return
	}
	if c.sinceSweep.Add(n) < limit/sweepEveryFraction {
		return
	}
	if !c.sweeping.CompareAndSwap(false, true) {
		return
	}
	c.sinceSweep.Store(0)
	run := func() {
		defer c.sweeping.Store(false)
		removed, freed, err := c.EvictToCap()
		if err != nil {
			log.Printf("image cache: eviction: %v", err)
		}
		if removed > 0 {
			log.Printf("image cache: evicted %d files (%d bytes) to stay under %d bytes", removed, freed, limit)
		}
	}
	if c.sweepNeeded != nil {
		c.sweepNeeded()
		run()
		return
	}
	go run()
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
		if info, err := os.Stat(path); err == nil {
			c.touch(path, info.ModTime())
			return path, true
		}
	}
	return "", false
}

// touch marks path as just used so eviction removes it last. It runs at most once per
// touchInterval per file; a failure (read-only volume) only means the file keeps its older
// rank, so it is logged and not returned.
func (c *ImageCache) touch(path string, mtime time.Time) {
	if c.MaxBytes() <= 0 || time.Since(mtime) < touchInterval {
		return
	}
	now := time.Now()
	if err := os.Chtimes(path, now, now); err != nil {
		log.Printf("image cache: touch %s: %v", filepath.Base(path), err)
	}
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

	c.noteWrite(n)
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
	case ImageSizeW780:
		return 780
	case ImageSizeW1280:
		return 1280
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
	case "780":
		return ImageSizeW780
	case "1280":
		return ImageSizeW1280
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
		case n <= 780:
			return ImageSizeW780
		case n <= 1280:
			return ImageSizeW1280
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
