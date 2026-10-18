package metadata

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// FR-150 image-cache cap. These run the real EvictToCap / noteWrite over a real directory;
// recency is set with os.Chtimes, the same signal the production code ranks by.

func writeCacheFile(t *testing.T, dir, name string, size int, age time.Duration) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(strings.Repeat("x", size)), 0o644); err != nil {
		t.Fatalf("write %s: %v", name, err)
	}
	mt := time.Now().Add(-age)
	if err := os.Chtimes(p, mt, mt); err != nil {
		t.Fatalf("chtimes %s: %v", name, err)
	}
	return p
}

func exists(p string) bool { _, err := os.Stat(p); return err == nil }

func TestEvictToCapRemovesOldestFirstDownToLowWater(t *testing.T) {
	dir := t.TempDir()
	c := NewImageCache(dir)
	c.SetMaxBytes(1000)
	// Five 300-byte files = 1500 bytes. Low water is 900, so exactly the two oldest go.
	var paths []string
	for i, age := range []time.Duration{50, 40, 30, 20, 10} { // minutes; index 0 is oldest
		paths = append(paths, writeCacheFile(t, dir, string(rune('a'+i))+".jpg", 300, age*time.Minute))
	}
	removed, freed, err := c.EvictToCap()
	if err != nil {
		t.Fatalf("EvictToCap: %v", err)
	}
	if removed != 2 || freed != 600 {
		t.Errorf("removed=%d freed=%d, want 2 and 600", removed, freed)
	}
	for i, p := range paths {
		want := i >= 2
		if exists(p) != want {
			t.Errorf("file %d exists=%v, want %v (oldest two evicted, newest three kept)", i, exists(p), want)
		}
	}
}

func TestEvictToCapUnderCapRemovesNothing(t *testing.T) {
	dir := t.TempDir()
	c := NewImageCache(dir)
	c.SetMaxBytes(1000)
	p := writeCacheFile(t, dir, "a.jpg", 400, time.Hour)
	if removed, _, err := c.EvictToCap(); err != nil || removed != 0 || !exists(p) {
		t.Errorf("removed=%d err=%v exists=%v, want nothing removed", removed, err, exists(p))
	}
}

func TestEvictToCapSparesFilesInsideTheGracePeriod(t *testing.T) {
	dir := t.TempDir()
	c := NewImageCache(dir)
	c.SetMaxBytes(500)
	if c.evictGrace != 2*time.Minute {
		t.Fatalf("default grace = %v, want 2m", c.evictGrace)
	}
	old := writeCacheFile(t, dir, "old.jpg", 400, time.Hour)
	fresh1 := writeCacheFile(t, dir, "fresh1.jpg", 400, 30*time.Second)
	fresh2 := writeCacheFile(t, dir, "fresh2.jpg", 400, 10*time.Second)
	removed, _, err := c.EvictToCap()
	if err != nil {
		t.Fatalf("EvictToCap: %v", err)
	}
	if removed != 1 || exists(old) {
		t.Errorf("removed=%d old exists=%v, want only the old file gone", removed, exists(old))
	}
	if !exists(fresh1) || !exists(fresh2) {
		t.Errorf("a file younger than the grace period was evicted (still over the cap, which is correct)")
	}
}

func TestEvictToCapAllInsideGraceRemovesNothing(t *testing.T) {
	dir := t.TempDir()
	c := NewImageCache(dir)
	c.SetMaxBytes(100)
	a := writeCacheFile(t, dir, "a.jpg", 400, 5*time.Second)
	b := writeCacheFile(t, dir, "b.jpg", 400, 20*time.Second)
	if removed, _, err := c.EvictToCap(); err != nil || removed != 0 || !exists(a) || !exists(b) {
		t.Errorf("removed=%d err=%v: a download in progress must never be evicted", removed, err)
	}
}

func TestZeroOrNegativeCapMeansUnlimited(t *testing.T) {
	for _, n := range []int64{0, -5} {
		dir := t.TempDir()
		c := NewImageCache(dir)
		c.SetMaxBytes(n)
		if c.MaxBytes() != 0 {
			t.Errorf("SetMaxBytes(%d): MaxBytes() = %d, want 0", n, c.MaxBytes())
		}
		var paths []string
		for i := 0; i < 5; i++ {
			paths = append(paths, writeCacheFile(t, dir, string(rune('a'+i))+".jpg", 1000, 24*time.Hour))
		}
		if removed, _, err := c.EvictToCap(); err != nil || removed != 0 {
			t.Errorf("cap %d: removed=%d err=%v, want 0", n, removed, err)
		}
		for _, p := range paths {
			if !exists(p) {
				t.Errorf("cap %d: %s was evicted with eviction off", n, filepath.Base(p))
			}
		}
	}
}

func TestEvictToCapOnlyTouchesImageFiles(t *testing.T) {
	dir := t.TempDir()
	c := NewImageCache(dir)
	c.SetMaxBytes(100)
	img := writeCacheFile(t, dir, "a.jpg", 400, time.Hour)
	note := writeCacheFile(t, dir, "notes.txt", 400, 2*time.Hour)
	if err := os.Mkdir(filepath.Join(dir, "sub.png"), 0o755); err != nil {
		t.Fatal(err)
	}
	if _, _, err := c.EvictToCap(); err != nil {
		t.Fatalf("EvictToCap: %v", err)
	}
	if exists(img) {
		t.Errorf("the image file should have been evicted")
	}
	if !exists(note) || !exists(filepath.Join(dir, "sub.png")) {
		t.Errorf("a non-image file or directory was removed")
	}
}

func TestDefaultCapIsOneGiB(t *testing.T) {
	if DefaultImageCacheMaxBytes != 1<<30 {
		t.Errorf("DefaultImageCacheMaxBytes = %d, want 1 GiB", DefaultImageCacheMaxBytes)
	}
}

// A cache hit on a file not touched for over an hour refreshes its mtime (so a poster still in
// use is not "oldest"); with eviction off nothing is written.
func TestCacheHitRefreshesRecencyOnlyWhenCapped(t *testing.T) {
	for _, capped := range []bool{true, false} {
		dir := t.TempDir()
		c := NewImageCache(dir)
		if capped {
			c.SetMaxBytes(1 << 20)
		}
		p := writeCacheFile(t, dir, "img1.jpg", 10, 3*time.Hour)
		if got, ok := c.GetCachedImage("img1"); !ok || got != p {
			t.Fatalf("GetCachedImage = %q, %v", got, ok)
		}
		info, err := os.Stat(p)
		if err != nil {
			t.Fatal(err)
		}
		fresh := time.Since(info.ModTime()) < time.Minute
		if fresh != capped {
			t.Errorf("capped=%v: mtime refreshed=%v, want %v", capped, fresh, capped)
		}
	}
}

// Writing past a twentieth of the cap since the last sweep requests one, and the sweep evicts.
func TestDownloadsTriggerASweepThatEvictsOldest(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "image/jpeg")
		_, _ = w.Write([]byte(strings.Repeat("y", 400)))
	}))
	defer srv.Close()
	dir := t.TempDir()
	c := NewImageCache(dir)
	c.SetMaxBytes(1000)
	sweeps := 0
	c.sweepNeeded = func() { sweeps++ }
	oldA := writeCacheFile(t, dir, "olda.jpg", 400, 3*time.Hour)
	oldB := writeCacheFile(t, dir, "oldb.jpg", 400, 2*time.Hour)
	// 800 on disk; this download makes 1200, over the 1000 cap.
	if _, err := c.CacheImage(context.Background(), "newone", srv.URL+"/p.jpg"); err != nil {
		t.Fatalf("CacheImage: %v", err)
	}
	if sweeps == 0 {
		t.Fatalf("no sweep was requested after the write")
	}
	if exists(oldA) {
		t.Errorf("the oldest file survived the sweep")
	}
	if !exists(oldB) || !exists(filepath.Join(dir, "newone.jpg")) {
		t.Errorf("sweep removed more than needed to reach low water (900): oldB=%v new=%v",
			exists(oldB), exists(filepath.Join(dir, "newone.jpg")))
	}
}

func TestDownloadsDoNotSweepWhenUnlimited(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("z"))
	}))
	defer srv.Close()
	c := NewImageCache(t.TempDir())
	c.SetMaxBytes(0)
	sweeps := 0
	c.sweepNeeded = func() { sweeps++ }
	if _, err := c.CacheImage(context.Background(), "x1", srv.URL); err != nil {
		t.Fatalf("CacheImage: %v", err)
	}
	if sweeps != 0 {
		t.Errorf("sweeps = %d with eviction off", sweeps)
	}
}
