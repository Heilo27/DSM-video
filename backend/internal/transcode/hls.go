package transcode

import (
	"context"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// HLSConfig contains configuration for HLS generation.
type HLSConfig struct {
	FFmpegPath     string        // Path to ffmpeg binary
	TempDir        string        // Base directory for transcode output
	SegmentSeconds int           // HLS segment duration (default: 4)
	VideoPreset    string        // x264 preset (default: "faster")
	VideoCRF       int           // x264 CRF quality (default: 23)
	AudioBitrate   string        // Audio bitrate (default: "192k")
	Threads        int           // Number of threads (default: 2)
	NicePriority   int           // Nice priority (default: 10 = medium-low; 19 = lowest possible)
	MaxConcurrent  int           // Max concurrent transcodes (default: 1)
}

// DefaultHLSConfig returns sensible defaults for NAS transcoding.
func DefaultHLSConfig() HLSConfig {
	return HLSConfig{
		SegmentSeconds: 2,
		VideoPreset:    "faster",
		VideoCRF:       23,
		AudioBitrate:   "192k",
		Threads:        2,
		NicePriority:   10,
		MaxConcurrent:  1,
	}
}

// HLSGenerator handles HLS segment generation.
type HLSGenerator struct {
	config HLSConfig

	mu        sync.Mutex
	active    int                     // Number of active transcodes
	sessions  map[string]*HLSSession  // Active HLS sessions
}

// SubtitleTrack describes an external subtitle file to include in HLS output.
type SubtitleTrack struct {
	Language string // BCP-47 language tag, e.g. "en", "fr"
	Name     string // Display name, e.g. "English"
	Path     string // Absolute path to source SRT/ASS/VTT file
	Offset   float64 // Timing offset in seconds (positive = delay, negative = advance)
}

// HLSSession represents an active transcoding session.
type HLSSession struct {
	SessionID     string
	VideoPath     string
	OutputDir     string
	Mode          PlaybackMode
	MaxHeight     int
	SubtitleTracks []SubtitleTrack
	StartedAt     time.Time
	CompletedAt   *time.Time
	LastAccess    time.Time
	Error         error
	cmd           *exec.Cmd
	cancel        context.CancelFunc
	stopped       bool // true when StopSession has already decremented g.active
}

// NewHLSGenerator creates a new HLS generator with the given config.
func NewHLSGenerator(config HLSConfig) *HLSGenerator {
	if config.FFmpegPath == "" {
		// Try to find ffmpeg in PATH
		if path, err := exec.LookPath("ffmpeg"); err == nil {
			config.FFmpegPath = path
		} else {
			// Common Synology locations
			for _, p := range []string{
				"/usr/bin/ffmpeg",
				"/usr/local/bin/ffmpeg",
				"/volume1/@appstore/ffmpeg/bin/ffmpeg",
				"/var/packages/ffmpeg/target/bin/ffmpeg",
			} {
				if _, err := exec.LookPath(p); err == nil {
					config.FFmpegPath = p
					break
				}
			}
		}
	}

	if config.TempDir == "" {
		config.TempDir = filepath.Join(os.TempDir(), "dsvideo_transcode")
	}

	if config.MaxConcurrent == 0 {
		config.MaxConcurrent = 1
	}

	return &HLSGenerator{
		config:   config,
		sessions: make(map[string]*HLSSession),
	}
}

// StartSession begins a new HLS transcoding session.
// It returns immediately and generates HLS segments in the background.
// maxHeight caps the output resolution (0 = no cap; only applies to FullTranscode).
// subtitles lists external subtitle files to convert and embed as HLS renditions.
func (g *HLSGenerator) StartSession(ctx context.Context, sessionID, videoPath string, mode PlaybackMode, maxHeight int, subtitles []SubtitleTrack) (*HLSSession, error) {
	g.mu.Lock()

	// Check if we've hit the concurrent limit
	if g.active >= g.config.MaxConcurrent {
		g.mu.Unlock()
		return nil, fmt.Errorf("maximum concurrent transcodes reached (%d)", g.config.MaxConcurrent)
	}

	// Check if session already exists
	if existing, ok := g.sessions[sessionID]; ok {
		existing.LastAccess = time.Now()
		g.mu.Unlock()
		return existing, nil
	}

	// Create output directory
	outputDir := filepath.Join(g.config.TempDir, sessionID)
	if err := os.MkdirAll(outputDir, 0755); err != nil {
		g.mu.Unlock()
		return nil, fmt.Errorf("create output dir: %w", err)
	}

	// Create session
	// Use context.Background() as parent so ffmpeg runs independently of the
	// HTTP request lifecycle. The session's own cancel function (assigned to
	// session.cancel below) provides explicit cleanup via StopSession.
	ctx, cancel := context.WithCancel(context.Background())
	session := &HLSSession{
		SessionID:      sessionID,
		VideoPath:      videoPath,
		OutputDir:      outputDir,
		Mode:           mode,
		MaxHeight:      maxHeight,
		SubtitleTracks: subtitles,
		StartedAt:      time.Now(),
		LastAccess:     time.Now(),
		cancel:         cancel,
	}

	g.sessions[sessionID] = session
	g.active++
	g.mu.Unlock()

	// Start transcoding in background
	go func() {
		err := g.runTranscode(ctx, session)

		g.mu.Lock()
		session.Error = err
		now := time.Now()
		session.CompletedAt = &now
		// Only decrement if StopSession hasn't already done so.
		if !session.stopped {
			g.active--
		}
		g.mu.Unlock()
	}()

	return session, nil
}

// GetSession returns an existing session by ID.
func (g *HLSGenerator) GetSession(sessionID string) (*HLSSession, bool) {
	g.mu.Lock()
	defer g.mu.Unlock()

	session, ok := g.sessions[sessionID]
	if ok {
		session.LastAccess = time.Now()
	}
	return session, ok
}

// StopSession stops and cleans up a session.
func (g *HLSGenerator) StopSession(sessionID string) error {
	g.mu.Lock()
	session, ok := g.sessions[sessionID]
	if !ok {
		g.mu.Unlock()
		return nil
	}

	// Cancel the transcode
	if session.cancel != nil {
		session.cancel()
	}

	// If the goroutine hasn't finished yet (CompletedAt is nil), decrement
	// active now and set stopped so the goroutine callback knows not to
	// double-decrement when it eventually exits.
	if session.CompletedAt == nil {
		session.stopped = true
		g.active--
	}

	delete(g.sessions, sessionID)
	g.mu.Unlock()

	// Clean up output directory
	return os.RemoveAll(session.OutputDir)
}

// runTranscode executes the FFmpeg command for transcoding, then converts any
// subtitle tracks to WebVTT and rewrites the master playlist to reference them.
func (g *HLSGenerator) runTranscode(ctx context.Context, session *HLSSession) error {
	if g.config.FFmpegPath == "" {
		return fmt.Errorf("ffmpeg not found")
	}

	args := g.buildFFmpegArgs(session)

	var cmd *exec.Cmd
	if g.config.NicePriority > 0 {
		niceArgs := []string{"-n", fmt.Sprintf("%d", g.config.NicePriority), g.config.FFmpegPath}
		niceArgs = append(niceArgs, args...)
		cmd = exec.CommandContext(ctx, "nice", niceArgs...)
	} else {
		cmd = exec.CommandContext(ctx, g.config.FFmpegPath, args...)
	}

	session.cmd = cmd
	cmd.Stdout = io.Discard

	logPath := filepath.Join(session.OutputDir, "ffmpeg.log")
	logFile, err := os.Create(logPath)
	if err != nil {
		cmd.Stderr = io.Discard
	} else {
		defer logFile.Close()
		cmd.Stderr = logFile
	}

	if err := cmd.Run(); err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return fmt.Errorf("ffmpeg failed: %w", err)
	}

	// Convert subtitle tracks to WebVTT and patch the master playlist.
	if len(session.SubtitleTracks) > 0 {
		g.addSubtitleRenditions(ctx, session)
	}

	return nil
}

// addSubtitleRenditions converts each SubtitleTrack to a WebVTT HLS playlist
// and rewrites master.m3u8 to include EXT-X-MEDIA subtitle renditions.
func (g *HLSGenerator) addSubtitleRenditions(ctx context.Context, session *HLSSession) {
	masterPath := filepath.Join(session.OutputDir, "master.m3u8")
	master, err := os.ReadFile(masterPath)
	if err != nil {
		log.Printf("[HLS] addSubtitleRenditions: read master: %v", err)
		return
	}

	var renditionLines []string
	for i, sub := range session.SubtitleTracks {
		vttName := fmt.Sprintf("subtitle_%d.m3u8", i)
		vttPath := filepath.Join(session.OutputDir, vttName)
		segPattern := filepath.Join(session.OutputDir, fmt.Sprintf("sub_%d_%%05d.vtt", i))

		ffArgs := []string{
			"-y",
			"-i", sub.Path,
		}
		if sub.Offset != 0 {
			ffArgs = append(ffArgs, "-itsoffset", fmt.Sprintf("%.3f", -sub.Offset))
		}
		ffArgs = append(ffArgs,
			"-c:s", "webvtt",
			"-f", "hls",
			"-hls_time", fmt.Sprintf("%d", g.config.SegmentSeconds),
			"-hls_list_size", "0",
			"-hls_segment_filename", segPattern,
			"-hls_playlist_type", "event",
			vttPath,
		)

		subCmd := exec.CommandContext(ctx, g.config.FFmpegPath, ffArgs...)
		subCmd.Stdout = io.Discard
		subCmd.Stderr = io.Discard
		if err := subCmd.Run(); err != nil {
			log.Printf("[HLS] subtitle convert failed (track %d %s): %v", i, sub.Language, err)
			continue
		}

		lang := sub.Language
		if lang == "" {
			lang = "und"
		}
		name := sub.Name
		if name == "" {
			name = lang
		}
		isDefault := "NO"
		if i == 0 {
			isDefault = "YES"
		}
		renditionLines = append(renditionLines,
			fmt.Sprintf(`#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",LANGUAGE="%s",NAME="%s",DEFAULT=%s,FORCED=NO,URI="%s"`,
				lang, name, isDefault, vttName),
		)
	}

	if len(renditionLines) == 0 {
		return
	}

	// Insert rendition tags before the first #EXT-X-STREAM-INF line and add
	// SUBTITLES="subs" attribute to each stream line.
	lines := strings.Split(string(master), "\n")
	var out []string
	injected := false
	for _, line := range lines {
		if !injected && strings.HasPrefix(line, "#EXT-X-STREAM-INF") {
			out = append(out, renditionLines...)
			injected = true
		}
		if strings.HasPrefix(line, "#EXT-X-STREAM-INF") && !strings.Contains(line, "SUBTITLES=") {
			line = strings.TrimRight(line, "\r") + `,SUBTITLES="subs"`
		}
		out = append(out, line)
	}

	if err := os.WriteFile(masterPath, []byte(strings.Join(out, "\n")), 0644); err != nil {
		log.Printf("[HLS] addSubtitleRenditions: write master: %v", err)
	}
}

// buildFFmpegArgs constructs the FFmpeg command line arguments.
func (g *HLSGenerator) buildFFmpegArgs(session *HLSSession) []string {
	outputPath := filepath.Join(session.OutputDir, "master.m3u8")
	segmentPath := filepath.Join(session.OutputDir, "segment_%05d.m4s")
	initPath := filepath.Join(session.OutputDir, "init.mp4")

	args := []string{
		"-y",                    // Overwrite output
		"-i", session.VideoPath, // Input file
	}

	// Video codec settings based on mode
	switch session.Mode {
	case RemuxOnly:
		// Copy video stream, only transcode audio
		args = append(args,
			"-c:v", "copy",
		)
	case FullTranscode:
		// Apply resolution cap before codec args when requested
		if session.MaxHeight > 0 {
			args = append(args,
				"-vf", fmt.Sprintf("scale=-2:min(ih\\,%d)", session.MaxHeight),
			)
		}
		// Full video transcode to H.264
		args = append(args,
			"-c:v", "libx264",
			"-preset", g.config.VideoPreset,
			"-crf", fmt.Sprintf("%d", g.config.VideoCRF),
			"-threads", fmt.Sprintf("%d", g.config.Threads),
			"-pix_fmt", "yuv420p", // Ensure compatibility
		)
	default:
		// Should not happen, but default to copy
		args = append(args, "-c:v", "copy")
	}

	// Audio transcoded to MP3 for NAS ffmpeg compatibility.
	// NAS ffmpeg is compiled without AAC encoder (--disable-encoder=aac) but
	// libmp3lame is available. MP3 is universally supported by HLS clients.
	// -map flags: explicitly select first video+audio streams; '?' makes audio
	// optional so ffmpeg doesn't fail if the source has no decodable audio track.
	args = append(args,
		"-map", "0:v:0",
		"-map", "0:a:0?",
		"-c:a", "libmp3lame",
		"-b:a", g.config.AudioBitrate,
		"-ac", "2", // Stereo (downmix surround if needed)
	)

	// HLS output settings
	segmentDuration := g.config.SegmentSeconds
	if segmentDuration == 0 {
		segmentDuration = 4
	}

	args = append(args,
		"-f", "hls",
		"-hls_time", fmt.Sprintf("%d", segmentDuration),
		"-hls_list_size", "0",       // Keep all segments in playlist
		"-hls_segment_type", "fmp4", // Fragmented MP4 (better compatibility)
		"-hls_fmp4_init_filename", filepath.Base(initPath),
		"-hls_segment_filename", segmentPath,
		// No hls_playlist_type — defaults to live-window which AirPlay and AVPlayer
		// handle correctly for in-progress transcodes. "event" causes the playlist to
		// grow unboundedly and can confuse AirPlay's playlist parser on long content.
		"-hls_flags", "independent_segments", // Each segment decodable independently (required for seeking)
		outputPath,
	)

	return args
}

// MasterPlaylistPath returns the path to the master playlist for a session.
func (g *HLSGenerator) MasterPlaylistPath(sessionID string) string {
	return filepath.Join(g.config.TempDir, sessionID, "master.m3u8")
}

// SegmentPath returns the path to a segment file.
func (g *HLSGenerator) SegmentPath(sessionID, filename string) string {
	return filepath.Join(g.config.TempDir, sessionID, filename)
}

// WaitForPlaylist waits for the master playlist to become available.
// This blocks until the playlist exists or context is cancelled.
func (g *HLSGenerator) WaitForPlaylist(ctx context.Context, sessionID string, timeout time.Duration) error {
	playlistPath := g.MasterPlaylistPath(sessionID)
	deadline := time.Now().Add(timeout)

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		if time.Now().After(deadline) {
			return fmt.Errorf("timeout waiting for playlist")
		}

		// Check if playlist exists and has content
		if info, err := os.Stat(playlistPath); err == nil && info.Size() > 0 {
			return nil
		}

		// Check if session has error
		if session, ok := g.GetSession(sessionID); ok && session.Error != nil {
			return session.Error
		}

		time.Sleep(100 * time.Millisecond)
	}
}

// IsReady returns true if the playlist is ready for streaming.
func (g *HLSGenerator) IsReady(sessionID string) bool {
	playlistPath := g.MasterPlaylistPath(sessionID)
	info, err := os.Stat(playlistPath)
	return err == nil && info.Size() > 0
}

// SessionStats contains statistics about a session.
type SessionStats struct {
	SessionID     string
	Mode          string
	StartedAt     time.Time
	CompletedAt   *time.Time
	LastAccess    time.Time
	Error         string
	SegmentCount  int
	OutputSizeKB  int64
}

// Stats returns statistics for a session.
func (g *HLSGenerator) Stats(sessionID string) (*SessionStats, error) {
	g.mu.Lock()
	session, ok := g.sessions[sessionID]
	g.mu.Unlock()

	if !ok {
		return nil, fmt.Errorf("session not found")
	}

	stats := &SessionStats{
		SessionID:   session.SessionID,
		Mode:        session.Mode.String(),
		StartedAt:   session.StartedAt,
		CompletedAt: session.CompletedAt,
		LastAccess:  session.LastAccess,
	}

	if session.Error != nil {
		stats.Error = session.Error.Error()
	}

	// Count segments and calculate size
	entries, err := os.ReadDir(session.OutputDir)
	if err == nil {
		for _, entry := range entries {
			if !entry.IsDir() {
				if info, err := entry.Info(); err == nil {
					stats.OutputSizeKB += info.Size() / 1024
				}
				if filepath.Ext(entry.Name()) == ".m4s" {
					stats.SegmentCount++
				}
			}
		}
	}

	return stats, nil
}

// ActiveSessions returns the number of currently active transcodes.
func (g *HLSGenerator) ActiveSessions() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.active
}

// AllSessions returns all session IDs.
func (g *HLSGenerator) AllSessions() []string {
	g.mu.Lock()
	defer g.mu.Unlock()

	ids := make([]string, 0, len(g.sessions))
	for id := range g.sessions {
		ids = append(ids, id)
	}
	return ids
}
