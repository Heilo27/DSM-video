package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"dsvideo/backend/internal/transcode"
)

// Embedded text subtitles (MKV/MP4 internal SRT/ASS/mov_text) are extracted to SRT in the
// BACKGROUND, at ingest time, so the first /playback of a title already lists them
// (TASK-1071; builds on TASK-739 naming and the TASK-752 ffmpeg budget).
//
// Layout: TranscodeDir/embedded_subs/<cacheKey(itemID)>/
//
//	stream_<N>.srt   one per extracted text stream (never a half-written file: see
//	                 transcode.ExtractEmbeddedSubtitles)
//	meta.json        written LAST, once the attempt is finished. It records every embedded
//	                 stream's language/title/codec/flags (so the cache names tracks exactly
//	                 as a live probe would, not "und"/"Subtitles") and the source file's
//	                 size + mtime (so a replaced or normalize-swapped file is detected and
//	                 re-extracted, and a stale cache is never served). meta.json is also
//	                 the "done" marker: a title with no embedded subs gets one too, so the
//	                 scanner does not re-probe it every pass.
//
// When it runs:
//   - the library scan calls ensureEmbeddedSubs for every file (cheap meta check; work is
//     queued only for files with no current cache), which backfills an existing library;
//   - the normalize worker's post-swap codec update calls refreshEmbeddedSubsAfterSwap;
//   - /playback calls ensureEmbeddedSubs for a title not cached yet (safety net).
//
// First play racing extraction: /playback NEVER waits for ffmpeg. It lists the image-based
// tracks and whichever text tracks are already on disk; text tracks still being extracted
// are omitted from that one response and appear on the next play. With ingest-time
// extraction that window is only a title played within minutes of being added.

const (
	embeddedSubsMetaFile   = "meta.json"
	embeddedSubsMetaVer    = 1
	subIngestQueueCap      = 1024
	subIngestLimiterWait   = 30 * time.Minute
	subIngestExtractBudget = 5 * time.Minute
	subIngestProbeBudget   = 60 * time.Second
)

// embeddedSubsMeta is the on-disk meta.json.
type embeddedSubsMeta struct {
	Version  int                          `json:"version"`
	SrcSize  int64                        `json:"srcSize"`
	SrcMtime int64                        `json:"srcMtimeNano"`
	Subs     []transcode.EmbeddedSubtitle `json:"subs"`
}

type subIngestJob struct {
	itemID    string
	videoPath string
	probe     *transcode.ProbeResult // optional: the scan/normalize probe, saves a second ffprobe
}

func (s *Server) embeddedSubsDir(itemID string) string {
	return filepath.Join(s.cfg.TranscodeDir, "embedded_subs", cacheKey(itemID))
}

func embeddedSubSrtPath(cacheDir string, streamIndex int) string {
	return filepath.Join(cacheDir, fmt.Sprintf("stream_%d.srt", streamIndex))
}

type embeddedSubsState int

const (
	embeddedSubsAbsent  embeddedSubsState = iota // no meta.json: never ingested (or pre-TASK-1071 cache)
	embeddedSubsStale                            // meta.json for a different version of the file
	embeddedSubsCurrent                          // meta.json matches the file on disk
)

// readEmbeddedSubsMeta classifies the cache for videoPath and returns its meta when readable.
func readEmbeddedSubsMeta(cacheDir, videoPath string) (*embeddedSubsMeta, embeddedSubsState) {
	raw, err := os.ReadFile(filepath.Join(cacheDir, embeddedSubsMetaFile))
	if err != nil {
		return nil, embeddedSubsAbsent
	}
	var m embeddedSubsMeta
	if err := json.Unmarshal(raw, &m); err != nil || m.Version != embeddedSubsMetaVer {
		return nil, embeddedSubsAbsent
	}
	info, err := os.Stat(videoPath)
	if err != nil || info.Size() != m.SrcSize || info.ModTime().UnixNano() != m.SrcMtime {
		return &m, embeddedSubsStale
	}
	return &m, embeddedSubsCurrent
}

// embeddedSubTrack builds the SubtitleTrack for one cached text stream. One home for the
// shape, used by every path that lists embedded subs.
func embeddedSubTrack(sub transcode.EmbeddedSubtitle, srtPath string, offset float64) transcode.SubtitleTrack {
	return transcode.SubtitleTrack{
		Language: sub.Language,
		Name:     embeddedSubName(sub),
		Path:     srtPath,
		Offset:   offset,
		Forced:   sub.Forced,
		Default:  sub.Default,
		Type:     subTypeFromForced(sub.Forced),
	}
}

// embeddedSubImageTrack surfaces an image-based sub (PGS/VobSub) so the client can list it;
// it is never extracted or OCR'd, so it carries no Path.
func embeddedSubImageTrack(sub transcode.EmbeddedSubtitle, offset float64) transcode.SubtitleTrack {
	return transcode.SubtitleTrack{
		Language: sub.Language,
		Name:     embeddedSubName(sub),
		Offset:   offset,
		Type:     "image",
	}
}

// embeddedTracksFromSubs lists the tracks for subs: image tracks always, text tracks only
// when their .srt is on disk.
func embeddedTracksFromSubs(cacheDir string, subs []transcode.EmbeddedSubtitle, offset float64) []transcode.SubtitleTrack {
	var tracks []transcode.SubtitleTrack
	for _, sub := range subs {
		if sub.IsImage {
			tracks = append(tracks, embeddedSubImageTrack(sub, offset))
			continue
		}
		srt := embeddedSubSrtPath(cacheDir, sub.Index)
		if _, err := os.Stat(srt); err == nil {
			tracks = append(tracks, embeddedSubTrack(sub, srt, offset))
		}
	}
	return tracks
}

// collectEmbeddedSubtitles returns SubtitleTrack entries for the subtitle streams embedded
// in the container, for /playback and the HLS pipeline to consume. It NEVER runs ffmpeg or
// ffprobe on the request path (a 15-track MKV took 15s+ on the NAS and clients timed out
// with -1001). See the file comment for when extraction actually happens and what a play
// that races it sees.
//
//   - meta.json current: the full, correctly named list comes from it.
//   - meta.json stale (file replaced / normalized): nothing from the old cache is served;
//     re-extraction is queued.
//   - no meta.json: re-extraction is queued; a pre-TASK-1071 cache (stream_N.srt files with
//     no meta) is still served so already-extracted titles do not lose their subs, named
//     from probeResult when this request had one, generically otherwise.
func (s *Server) collectEmbeddedSubtitles(itemID, videoPath string, offset float64, probeResult *transcode.ProbeResult) []transcode.SubtitleTrack {
	if s.cfg.FFmpegPath == "" {
		return nil
	}
	// TASK-800: never hand a path outside a media root to ffmpeg (probe or extraction).
	if !s.pathWithinMediaRoot(videoPath) {
		log.Printf("[subtitles] SECURITY: path %q for item %s not within any media root — skipping ffmpeg", filepath.Clean(videoPath), itemID)
		return nil
	}

	cacheDir := s.embeddedSubsDir(itemID)
	meta, state := readEmbeddedSubsMeta(cacheDir, videoPath)
	if state == embeddedSubsCurrent {
		return embeddedTracksFromSubs(cacheDir, meta.Subs, offset)
	}

	s.ensureEmbeddedSubs(itemID, videoPath, probeResult)
	if state == embeddedSubsStale {
		return nil
	}
	// Legacy cache (no meta.json).
	if probeResult != nil && len(probeResult.EmbeddedSubs) > 0 {
		return embeddedTracksFromSubs(cacheDir, probeResult.EmbeddedSubs, offset)
	}
	return legacyCachedEmbeddedSubtitles(cacheDir, offset)
}

// legacyCachedEmbeddedSubtitles lists stream_N.srt files left by the pre-TASK-1071 code,
// which kept no language/title on disk. Generic names are all that can be said.
func legacyCachedEmbeddedSubtitles(cacheDir string, offset float64) []transcode.SubtitleTrack {
	entries, err := os.ReadDir(cacheDir)
	if err != nil {
		return nil
	}
	var tracks []transcode.SubtitleTrack
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".srt") {
			continue
		}
		tracks = append(tracks, transcode.SubtitleTrack{
			Language: "und",
			Name:     "Subtitles",
			Path:     filepath.Join(cacheDir, e.Name()),
			Offset:   offset,
		})
	}
	return tracks
}

// ensureEmbeddedSubs queues background extraction of videoPath's embedded text subtitles
// unless the cache is already current. It returns immediately and never blocks on ffmpeg.
// probe is optional (the probe the caller already ran); without it the worker probes.
// Singleflight per item, so the scanner, normalize and concurrent plays collapse to one job.
func (s *Server) ensureEmbeddedSubs(itemID, videoPath string, probe *transcode.ProbeResult) {
	if itemID == "" || videoPath == "" || s.cfg.FFmpegPath == "" || s.cfg.TranscodeDir == "" {
		return
	}
	if !s.pathWithinMediaRoot(videoPath) {
		log.Printf("[subtitles] SECURITY: path %q for item %s not within any media root — skipping ffmpeg", filepath.Clean(videoPath), itemID)
		return
	}
	if _, state := readEmbeddedSubsMeta(s.embeddedSubsDir(itemID), videoPath); state == embeddedSubsCurrent {
		return
	}
	if probe == nil && s.prober == nil {
		return // nothing to learn the streams from
	}

	s.subIngestOnce.Do(func() {
		s.subIngestQ = make(chan subIngestJob, subIngestQueueCap)
		go s.runSubIngestWorker(s.subIngestQ)
	})

	key := "ingest:" + itemID
	s.subExtractMu.Lock()
	if s.subExtractInFlight == nil {
		s.subExtractInFlight = make(map[string]chan struct{})
	}
	if _, inflight := s.subExtractInFlight[key]; inflight {
		s.subExtractMu.Unlock()
		return
	}
	s.subExtractInFlight[key] = make(chan struct{})
	s.subExtractMu.Unlock()

	select {
	case s.subIngestQ <- subIngestJob{itemID: itemID, videoPath: videoPath, probe: probe}:
	default:
		// Queue full (huge first scan). Drop: the next scan or play re-queues it.
		s.clearSubIngestInFlight(key)
		log.Printf("[subs] ingest queue full — %s will be retried on a later scan or play", itemID)
	}
}

func (s *Server) clearSubIngestInFlight(key string) {
	s.subExtractMu.Lock()
	if done, ok := s.subExtractInFlight[key]; ok {
		delete(s.subExtractInFlight, key)
		close(done)
	}
	s.subExtractMu.Unlock()
}

// runSubIngestWorker serialises extraction jobs: one title at a time, each holding one slot
// of the shared ffmpeg budget for its single pass, so a first scan of a large library can
// never swamp the NAS or starve live playback (blocking Acquire, off the request path).
func (s *Server) runSubIngestWorker(q <-chan subIngestJob) {
	for job := range q {
		s.runSubIngestJob(job)
		s.clearSubIngestInFlight("ingest:" + job.itemID)
	}
}

func (s *Server) runSubIngestJob(job subIngestJob) {
	info, err := os.Stat(job.videoPath)
	if err != nil {
		return // file left since it was queued
	}
	cacheDir := s.embeddedSubsDir(job.itemID)
	if _, state := readEmbeddedSubsMeta(cacheDir, job.videoPath); state == embeddedSubsCurrent {
		return
	}

	probe := job.probe
	if probe == nil {
		if s.prober == nil {
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), subIngestProbeBudget)
		p, perr := s.prober.Probe(ctx, job.videoPath)
		cancel()
		if perr != nil || p == nil {
			// No meta written: a transient probe failure is retried on the next scan/play.
			log.Printf("[subs] probe failed for %s, will retry later: %v", job.itemID, perr)
			return
		}
		probe = p
	}

	// Whatever is in the dir belongs to a previous version of the file (or a pre-meta cache).
	_ = os.RemoveAll(cacheDir)

	var streams []transcode.SubtitleExtraction
	for _, sub := range probe.EmbeddedSubs {
		if !sub.IsImage {
			streams = append(streams, transcode.SubtitleExtraction{StreamIndex: sub.Index, DestPath: embeddedSubSrtPath(cacheDir, sub.Index)})
		}
	}

	if len(streams) > 0 {
		if !s.extractEmbeddedStreams(job, streams) {
			return // interrupted (shutdown / budget); no meta, so it is retried
		}
	}
	if err := writeEmbeddedSubsMeta(cacheDir, info, probe.EmbeddedSubs); err != nil {
		log.Printf("[subs] could not record embedded-subtitle cache for %s: %v", job.itemID, err)
		return
	}
	log.Printf("[subs] embedded subtitles ready for %s (%d text, %d streams total)", job.itemID, len(streams), len(probe.EmbeddedSubs))
}

// extractEmbeddedStreams runs the single-pass extraction under the shared ffmpeg limiter.
// It returns false only when the attempt was cut short by its time budget (retry later);
// an ffmpeg failure is final for this file version (logged, meta written by the caller
// with whatever was produced), so a file ffmpeg cannot read is not re-run every scan.
func (s *Server) extractEmbeddedStreams(job subIngestJob, streams []transcode.SubtitleExtraction) bool {
	waitCtx, cancelWait := context.WithTimeout(context.Background(), subIngestLimiterWait)
	defer cancelWait()
	if err := s.ffmpegLimiter.Acquire(waitCtx); err != nil {
		log.Printf("[subs] embedded extract aborted for %s: %v", job.itemID, err)
		return false
	}
	defer s.ffmpegLimiter.Release()

	exCtx, cancel := context.WithTimeout(context.Background(), subIngestExtractBudget)
	defer cancel()
	err := transcode.ExtractEmbeddedSubtitles(exCtx, s.cfg.FFmpegPath, job.videoPath, streams)
	if err == nil {
		return true
	}
	if exCtx.Err() != nil {
		log.Printf("[subs] embedded extract for %s ran out of time: %v", job.itemID, err)
		return false
	}
	// One stream ffmpeg cannot convert sinks the whole pass. Salvage the others one by one
	// (slower, but only on this rare path) so a single odd track does not cost every track.
	log.Printf("[subs] single-pass extract failed for %s (%v) — retrying stream by stream", job.itemID, err)
	for _, st := range streams {
		if exErr := transcode.ExtractEmbeddedSubtitle(exCtx, s.cfg.FFmpegPath, job.videoPath, st.StreamIndex, st.DestPath); exErr != nil {
			log.Printf("[subs] embedded extract failed for %s stream %d: %v", job.itemID, st.StreamIndex, exErr)
			if exCtx.Err() != nil {
				return false
			}
		}
	}
	return true
}

// writeEmbeddedSubsMeta records the finished attempt. Written to a temp name and renamed so
// a reader never sees a half-written meta.json.
func writeEmbeddedSubsMeta(cacheDir string, info os.FileInfo, subs []transcode.EmbeddedSubtitle) error {
	if err := os.MkdirAll(cacheDir, 0o755); err != nil {
		return fmt.Errorf("create cache dir: %w", err)
	}
	raw, err := json.Marshal(embeddedSubsMeta{
		Version: embeddedSubsMetaVer, SrcSize: info.Size(), SrcMtime: info.ModTime().UnixNano(), Subs: subs,
	})
	if err != nil {
		return fmt.Errorf("encode meta: %w", err)
	}
	tmp := filepath.Join(cacheDir, embeddedSubsMetaFile+".tmp")
	if err := os.WriteFile(tmp, raw, 0o644); err != nil {
		return fmt.Errorf("write meta: %w", err)
	}
	if err := os.Rename(tmp, filepath.Join(cacheDir, embeddedSubsMetaFile)); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("publish meta: %w", err)
	}
	return nil
}

// refreshEmbeddedSubsAfterSwap is the normalize worker's post-swap hook (via the codec
// update callback). Converting Movie.mkv to Movie.mp4 changes the item id (so the cache
// keyed to the old id is orphaned) and may change stream order, so: drop the old id's cache,
// then extract from the converted file under the id the item now has. The file fingerprint
// in meta.json already makes a same-path remux regenerate; this makes it prompt rather
// than waiting for the next scan.
func (s *Server) refreshEmbeddedSubsAfterSwap(oldID, newPath string, probe *transcode.ProbeResult) {
	if s.cfg.TranscodeDir == "" {
		return
	}
	cleanPath := filepath.Clean(newPath)
	currentID := itemIDFromPath(cleanPath)
	if currentID != oldID {
		// Re-key falls back to a path-only repoint (row keeps oldID) when the new id is absent.
		var one int
		if s.db != nil && s.db.QueryRow(`SELECT 1 FROM items WHERE id = ?`, currentID).Scan(&one) != nil {
			currentID = oldID
		}
	}
	if currentID != oldID {
		if err := os.RemoveAll(s.embeddedSubsDir(oldID)); err != nil {
			log.Printf("[subs] could not remove orphaned subtitle cache for %s: %v", oldID, err)
		}
	}
	s.ensureEmbeddedSubs(currentID, cleanPath, probe)
}
