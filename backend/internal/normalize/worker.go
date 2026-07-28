package normalize

import (
	"context"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"dsvideo/backend/internal/transcode"
)

// queueItem is one unit of normalization work: which DB item it is, the file to
// convert, and the media root that file lives under (so the worker can preserve
// the relative path when backing the original up). mediaRoot is captured per-item
// at Enqueue time because a single server has several roots (Movies/TV/Home).
type queueItem struct {
	itemID    string
	path      string
	mediaRoot string
}

// CodecUpdateFunc re-probes a freshly converted file and updates the DB row for
// itemID so needs_transcode flips to 0 and change_seq bumps (clients then see the
// item as DirectPlay on next sync). It is injected from main.go as a closure over
// s.updateCodecInfo + s.prober so the normalize package stays free of the DB layer.
type CodecUpdateFunc func(itemID, newPath string)

// IdleFunc reports whether the server is currently idle enough to run a background
// conversion: no active HLS transcodes AND no recently-touched playback session.
// Injected from main.go (it needs hlsGenerator.ActiveSessions and the playSessions
// map). The worker polls it before every job and never competes with live playback.
type IdleFunc func() bool

// NormalizeWorker runs the single-threaded background normalization pipeline.
//
// Concurrency model (one job at a time, never competing with playback):
//  1. Items arrive via Enqueue (deduplicated against an in-flight set + the channel).
//  2. The worker goroutine pulls one item, then WAITS for the server to be idle,
//     polling IdleFunc every idlePollInterval. Background work only starts when no
//     one is watching.
//  3. It then TryAcquires the SHARED ffmpeg limiter with a short timeout. If the
//     budget is saturated (a viewer just started), it yields — requeues the item and
//     moves on — rather than blocking a live transcode out of a slot.
//  4. Convert runs (nice 19). On verified success the worker performs the tiny
//     move+swap window (mark IsConverting → back up original → rename tmp into place
//     → unmark), then fires the codec-update callback. On any failure the original is
//     left untouched and the item is dropped (logged).
type NormalizeWorker struct {
	ffmpegPath  string
	ffprobePath string
	backupDir   string
	maxHeight   int

	limiter     *transcode.FFmpegLimiter
	isIdle      IdleFunc
	updateCodec CodecUpdateFunc

	queue chan queueItem

	mu sync.Mutex
	// queued: items waiting in the channel or being processed, so Enqueue dedups.
	queued map[string]struct{}
	// converting: items in the brief mid-swap window (original being moved / file
	// replaced). handlePlayback consults IsConverting to return a 409 ONLY during
	// this tiny window — NOT during the whole encode, so on-demand playback of a
	// still-queued/encoding item keeps working (slowly, via the normal transcode path).
	converting map[string]struct{}
	// permaFailed: items whose failure is deterministic — a corrupt/unreadable file
	// (ffprobe exit 1) or a conversion target blocked by an unrelated existing file.
	// Without this, every library scan re-enqueues them and the worker re-probes and
	// re-fails forever, spamming the log and burning an idle slot that a convertible
	// file should have had. Observed in production: three unreadable DS9 episodes and
	// one .AVI whose .mp4 twin already exists, retried on every scan for hours.
	//
	// Deliberately in-memory only: a restart clears it, so a genuinely fixed file
	// (user replaced the corrupt download, removed the duplicate) gets another chance
	// without any manual reset. The value records why, for the status endpoint/log.
	permaFailed map[string]string
}

// Tunables. queueCapacity bounds memory if a huge first scan enqueues thousands of
// files; overflow is dropped (the next scan re-enqueues). idlePollInterval ~30s is
// the spec's idle poll cadence — long enough to be cheap, short enough to start work
// promptly once a viewer stops. acquireTimeout mirrors the trickplay yield budget:
// a short wait, then back off so we never hold a live transcode out of a slot.
const (
	queueCapacity    = 256
	idlePollInterval = 30 * time.Second
	acquireTimeout   = 2 * time.Second
	// requeueBackoff spaces out a yielded item's retry so a busy server isn't spun on.
	requeueBackoff = 1 * time.Minute
)

// NewNormalizeWorker constructs a worker. Call Start to launch its goroutine.
func NewNormalizeWorker(
	ffmpegPath, ffprobePath, backupDir string,
	maxHeight int,
	limiter *transcode.FFmpegLimiter,
	isIdle IdleFunc,
	updateCodec CodecUpdateFunc,
) *NormalizeWorker {
	if maxHeight <= 0 {
		maxHeight = 720
	}
	return &NormalizeWorker{
		ffmpegPath:  ffmpegPath,
		ffprobePath: ffprobePath,
		backupDir:   filepath.Clean(backupDir),
		maxHeight:   maxHeight,
		limiter:     limiter,
		isIdle:      isIdle,
		updateCodec: updateCodec,
		queue:       make(chan queueItem, queueCapacity),
		queued:      make(map[string]struct{}),
		converting:  make(map[string]struct{}),
		permaFailed: make(map[string]string),
	}
}

// Enqueue schedules itemID/path for normalization, deduplicating against anything
// already queued or in progress. mediaRoot is the configured library root the file
// lives under (used to preserve the relative path under backupDir). Safe to call
// from the scanner on every scan — already-queued items are ignored, and a full
// channel drops the item (it'll be re-seen on the next scan).
func (w *NormalizeWorker) Enqueue(itemID, path, mediaRoot string) {
	if w == nil || itemID == "" || path == "" {
		return
	}
	w.mu.Lock()
	if _, dup := w.queued[itemID]; dup {
		w.mu.Unlock()
		return
	}
	// Deterministic prior failure — don't re-queue it every scan. Cleared on restart.
	if _, dead := w.permaFailed[itemID]; dead {
		w.mu.Unlock()
		return
	}
	w.queued[itemID] = struct{}{}
	w.mu.Unlock()

	select {
	case w.queue <- queueItem{itemID: itemID, path: path, mediaRoot: mediaRoot}:
	default:
		// Queue full — drop and un-mark so a later scan can re-enqueue.
		w.mu.Lock()
		delete(w.queued, itemID)
		w.mu.Unlock()
		log.Printf("[normalize] queue full — dropped %s (will retry next scan)", itemID)
	}
}

// IsConverting reports whether itemID is in the brief mid-swap window. The playback
// handler uses this to emit a 409 {"status":"converting"} during the few seconds the
// file is being replaced on disk — see the worker's swap step. Mutex-guarded.
func (w *NormalizeWorker) IsConverting(itemID string) bool {
	if w == nil {
		return false
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	_, ok := w.converting[itemID]
	return ok
}

// Start launches the worker goroutine. ctx cancellation stops it after the current
// job. Call exactly once.
func (w *NormalizeWorker) Start(ctx context.Context) {
	go w.run(ctx)
}

func (w *NormalizeWorker) run(ctx context.Context) {
	log.Printf("[normalize] worker started (backup=%s maxHeight=%d)", w.backupDir, w.maxHeight)
	for {
		select {
		case <-ctx.Done():
			log.Printf("[normalize] worker stopping: %v", ctx.Err())
			return
		case item := <-w.queue:
			w.process(ctx, item)
		}
	}
}

// process handles a single item end to end: clear its queued mark (so a future scan
// can re-enqueue if this run fails), wait for idle, acquire a slot or yield, convert,
// and on success do the verified swap + codec update.
func (w *NormalizeWorker) process(ctx context.Context, item queueItem) {
	// Un-mark from the queued set up front: the item is now "in this run". If we yield
	// or fail, a subsequent scan is free to re-enqueue it.
	w.mu.Lock()
	delete(w.queued, item.itemID)
	w.mu.Unlock()

	// The file may have been deleted, already converted, or renamed since enqueue.
	if _, err := os.Stat(item.path); err != nil {
		return
	}

	// Re-decide against the CURRENT file: a prior run (or convert-library.sh) may have
	// already normalized it. Skip if it now DirectPlays. Cheap insurance against
	// double work and against converting a file that no longer needs it.
	prober := transcode.NewProber(w.ffprobePath)
	probeCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	probe, probeErr := prober.Probe(probeCtx, item.path)
	cancel()
	if probeErr != nil {
		// ffprobe can't read the file — corrupt, truncated, or not really video. This
		// will fail identically on every future scan, so retire it instead of looping.
		log.Printf("[normalize] probe failed for %s (%s) — giving up (will retry after a server restart): %v", item.itemID, item.path, probeErr)
		w.markPermaFailed(item.itemID, "ffprobe could not read the file")
		return
	}
	action := Decide(probe, filepath.Ext(item.path))
	if action == ActionSkip {
		return
	}

	// Check the clobber condition BEFORE spending the encode, not just after. The
	// post-convert guard below is the authoritative one (the target could appear while
	// we encode), but without this pre-check a blocked item pays for a full re-encode
	// on every single scan before being thrown away — observed in production as the
	// same .AVI burning four encodes in two hours. Cheap stat, saves hours of NAS CPU.
	if wouldClobber(item.path, TargetOutputPath(item.path)) {
		log.Printf("[normalize] target for %s already exists as a different file — skipping before encode (delete whichever copy you don't want)", item.path)
		w.markPermaFailed(item.itemID, "conversion target already exists as a different file")
		return
	}

	// Wait until the server is idle. Background normalization must never run while a
	// viewer is active; poll the injected idle func. Bail on ctx cancel.
	if !w.waitForIdle(ctx) {
		// Cancelled while waiting — requeue for next time and stop.
		w.requeueLater(item)
		return
	}

	// Draw a slot from the SHARED ffmpeg budget via TryAcquire — the yield mechanism.
	// If the budget is saturated (live playback grabbed the slots between our idle
	// check and now), we do NOT block: we give the item back to the queue after a
	// backoff and let live playback win. Live transcodes use blocking Acquire and
	// always eventually get a slot; we are the polite background citizen.
	if !w.limiter.TryAcquire(ctx, acquireTimeout) {
		w.requeueLater(item)
		return
	}
	// Convert holds the slot for the full ffmpeg run; release on return.
	outTmp, err := Convert(ctx, w.ffmpegPath, w.ffprobePath, item.path, action, w.maxHeight)
	w.limiter.Release()

	if err != nil {
		// Data-safety: original is untouched on any failure. Log and move on.
		log.Printf("[normalize] convert %s failed for %s — original left in place: %v", action, item.path, err)
		return
	}

	// SUCCESS path. Everything from here to the codec update is the tiny "converting"
	// window: mark IsConverting, back up the original, swap the new file into place,
	// then unmark. This is the only span during which handlePlayback should 409 —
	// it lasts a couple of filesystem renames, not the whole encode.
	target := TargetOutputPath(item.path)

	w.mu.Lock()
	w.converting[item.itemID] = struct{}{}
	w.mu.Unlock()
	defer func() {
		w.mu.Lock()
		delete(w.converting, item.itemID)
		w.mu.Unlock()
	}()

	// Worf P1-4 (TASK-755): refuse to clobber a pre-existing UNRELATED file. When the
	// conversion target differs from the source (e.g. Movie.mkv → Movie.mp4) a DIFFERENT
	// Movie.mp4 may already exist as its own library item; os.Rename would destroy it with
	// no backup. If target != source and target already exists on disk, abort this
	// conversion: drop the temp, leave the original untouched, warn. (When target == source
	// the original is about to be moved into the backup tree below, so a same-name swap is
	// safe and is NOT blocked here.)
	if wouldClobber(item.path, target) {
		// The destination name is taken by an unrelated file (typically the SAME title
		// already converted, e.g. "Movie.AVI" beside an existing "Movie.mp4"). Nothing
		// about a later scan changes this, and we've already burned a full encode to get
		// here — retire it so we don't pay that cost again on every scan.
		log.Printf("[normalize] target %s already exists as a different file — aborting conversion of %s to avoid clobber (giving up; delete whichever copy you don't want)", target, item.path)
		_ = os.Remove(outTmp)
		w.markPermaFailed(item.itemID, "conversion target already exists as a different file")
		return
	}

	if err := w.backupOriginal(item.path, item.mediaRoot); err != nil {
		// Could not safely move the original aside — abandon the swap, delete our
		// verified temp, and leave the original playable. No data lost.
		log.Printf("[normalize] backup of %s failed — discarding conversion: %v", item.path, err)
		_ = os.Remove(outTmp)
		return
	}

	// Move the verified temp into the final "<stem>.mp4" name. If src was already
	// "<stem>.mp4" (a remux of an .mp4 — rare) the original is now in the backup tree,
	// so this rename can't clobber anything live. For a different-path target (.mkv →
	// .mp4) the clobber guard above already proved target was absent.
	if err := os.Rename(outTmp, target); err != nil {
		// The rename failed but the original is already in the backup tree. Restore it
		// so the library item stays playable, and drop the temp.
		log.Printf("[normalize] swap-in of %s failed — restoring original: %v", target, err)
		_ = w.restoreOriginal(item.path, item.mediaRoot)
		_ = os.Remove(outTmp)
		return
	}

	log.Printf("[normalize] OK (%s): %s -> %s", action, item.path, target)

	// Re-probe + update the DB so needs_transcode=0 and change_seq bumps. Done inside
	// the converting window's defer scope but after the swap, so by the time the 409
	// window closes the DB already reflects DirectPlay.
	if w.updateCodec != nil {
		w.updateCodec(item.itemID, target)
	}
}

// wouldClobber reports whether renaming the converted temp into target would destroy a
// pre-existing UNRELATED file. Worf P1-4 (TASK-755): only a DIFFERENT-path target is a
// clobber risk — when target == src the original is moved to the backup tree first, so a
// same-name swap is always safe. A different-path target that already exists on disk is a
// separate file (its own library item) and must not be overwritten.
// markPermaFailed retires itemID from future scans, recording why. See permaFailed.
func (w *NormalizeWorker) markPermaFailed(itemID, reason string) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.permaFailed[itemID] = reason
}

// Stats is a point-in-time view of the worker for the admin status endpoint.
type Stats struct {
	// Queued is the number of items waiting or in progress.
	Queued int `json:"queued"`
	// Capacity is the channel bound; Queued at Capacity means scans are dropping
	// items (they get re-enqueued next scan, but throughput is the limit).
	Capacity int `json:"capacity"`
	// Converting is the count in the mid-swap window (normally 0 or 1).
	Converting int `json:"converting"`
	// Retired are items that failed deterministically and won't be retried until
	// the server restarts, mapped to the reason.
	Retired map[string]string `json:"retired"`
	// MaxHeight is the normalization height cap — surfaced because it silently
	// determines whether conversions downscale the user's originals.
	MaxHeight int `json:"maxHeight"`
}

// IsIdleNow reports whether the server currently looks idle enough to convert. The
// worker blocks on this before every job, so a status endpoint showing queued>0 with
// idle=false explains "why is nothing converting?" without reading the log.
func (w *NormalizeWorker) IsIdleNow() bool {
	if w == nil || w.isIdle == nil {
		return false
	}
	return w.isIdle()
}

// Stats returns a snapshot for diagnostics. Safe on a nil worker (auto-normalize off).
func (w *NormalizeWorker) Stats() Stats {
	if w == nil {
		return Stats{}
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	retired := make(map[string]string, len(w.permaFailed))
	for k, v := range w.permaFailed {
		retired[k] = v
	}
	return Stats{
		Queued:     len(w.queued),
		Capacity:   queueCapacity,
		Converting: len(w.converting),
		Retired:    retired,
		MaxHeight:  w.maxHeight,
	}
}

// PermaFailed returns a snapshot of retired items → reason, for logging/diagnostics.
func (w *NormalizeWorker) PermaFailed() map[string]string {
	if w == nil {
		return nil
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	out := make(map[string]string, len(w.permaFailed))
	for k, v := range w.permaFailed {
		out[k] = v
	}
	return out
}

func wouldClobber(src, target string) bool {
	if target == src {
		return false
	}
	_, err := os.Stat(target)
	return err == nil
}

// waitForIdle blocks until isIdle() is true or ctx is cancelled, polling every
// idlePollInterval. Returns true if idle was reached, false on cancellation. A nil
// idle func is treated as "always idle" (defensive; main.go always injects one).
func (w *NormalizeWorker) waitForIdle(ctx context.Context) bool {
	if w.isIdle == nil || w.isIdle() {
		return true
	}
	ticker := time.NewTicker(idlePollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return false
		case <-ticker.C:
			if w.isIdle() {
				return true
			}
		}
	}
}

// requeueLater re-enqueues an item after requeueBackoff without blocking the worker
// loop, so a busy/saturated server doesn't get spun on. The item is re-marked queued
// immediately to preserve dedup across the backoff.
func (w *NormalizeWorker) requeueLater(item queueItem) {
	w.mu.Lock()
	if _, dup := w.queued[item.itemID]; dup {
		w.mu.Unlock()
		return
	}
	w.queued[item.itemID] = struct{}{}
	w.mu.Unlock()

	go func() {
		time.Sleep(requeueBackoff)
		select {
		case w.queue <- item:
		default:
			w.mu.Lock()
			delete(w.queued, item.itemID)
			w.mu.Unlock()
		}
	}()
}

// backupOriginal moves src into the backup tree under backupDir, preserving its path
// relative to mediaRoot, and sets the moved file's mtime to NOW. The mtime is the
// retention clock the reaper reads — "now" means "deleted 7 days from the moment we
// stopped needing it", matching the spec. Parent dirs are created as needed.
func (w *NormalizeWorker) backupOriginal(src, mediaRoot string) error {
	dest := w.backupPath(src, mediaRoot)
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return err
	}
	if err := moveFile(src, dest); err != nil {
		return err
	}
	now := time.Now()
	if err := os.Chtimes(dest, now, now); err != nil {
		// Non-fatal: the file is safely backed up; a missed mtime just means the reaper
		// uses whatever mtime the move preserved. Log via returned-nil + caller logs OK.
		log.Printf("[normalize] could not set backup mtime on %s: %v", dest, err)
	}
	return nil
}

// restoreOriginal moves a backed-up original back to src (best-effort rollback when
// the post-backup swap fails). mediaRoot must match the value passed to backupOriginal.
func (w *NormalizeWorker) restoreOriginal(src, mediaRoot string) error {
	dest := w.backupPath(src, mediaRoot)
	return moveFile(dest, src)
}

// backupPath computes the destination inside the backup tree for src, preserving the
// path relative to mediaRoot when src is under it (e.g. /vol/video/Movies/a/b.mkv with
// root /vol/video/Movies → <backupDir>/a/b.mkv). When src is not under mediaRoot, fall
// back to the absolute path minus its leading separator (mirrors the shell script's
// `${src#/}`), so the original is still preserved somewhere recoverable.
func (w *NormalizeWorker) backupPath(src, mediaRoot string) string {
	cleanSrc := filepath.Clean(src)
	if mediaRoot != "" {
		cleanRoot := filepath.Clean(mediaRoot)
		if rel, err := filepath.Rel(cleanRoot, cleanSrc); err == nil && !strings.HasPrefix(rel, "..") {
			return filepath.Join(w.backupDir, rel)
		}
	}
	return filepath.Join(w.backupDir, strings.TrimPrefix(cleanSrc, string(filepath.Separator)))
}

// StartRetentionReaper launches an hourly ticker that deletes files under backupDir
// whose mtime is older than retentionDays. Backups are the safety net after a verified
// conversion; once the user has had a week to notice a bad conversion they are reclaimed.
// Mirrors the hourly-reaper style of the playSessions/cache loops in main.go. ctx-cancel
// stops it. (TASK-755)
func (w *NormalizeWorker) StartRetentionReaper(ctx context.Context, retentionDays int) {
	if retentionDays <= 0 {
		retentionDays = 7
	}
	go func() {
		ticker := time.NewTicker(1 * time.Hour)
		defer ticker.Stop()
		// Run once shortly after start so a restart doesn't wait a full hour to reclaim
		// already-expired backups.
		w.reapBackups(retentionDays)
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				w.reapBackups(retentionDays)
			}
		}
	}()
}

// reapBackups walks backupDir and removes files older than retentionDays by mtime,
// then prunes any directories left empty. Errors are logged, never fatal.
func (w *NormalizeWorker) reapBackups(retentionDays int) {
	if w.backupDir == "" {
		return
	}
	if _, err := os.Stat(w.backupDir); err != nil {
		return // nothing backed up yet
	}
	cutoff := time.Now().Add(-time.Duration(retentionDays) * 24 * time.Hour)
	var removed int
	_ = filepath.Walk(w.backupDir, func(path string, info os.FileInfo, err error) error {
		if err != nil || info == nil {
			return nil
		}
		if info.IsDir() {
			return nil
		}
		if info.ModTime().Before(cutoff) {
			if err := os.Remove(path); err != nil {
				log.Printf("[normalize] retention: failed to delete %s: %v", path, err)
			} else {
				removed++
			}
		}
		return nil
	})
	if removed > 0 {
		log.Printf("[normalize] retention: reclaimed %d expired backup file(s) older than %dd", removed, retentionDays)
		pruneEmptyDirs(w.backupDir)
	}
}
