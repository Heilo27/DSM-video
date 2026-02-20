package transcode

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
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
	NicePriority   int           // Nice priority (default: 19 = lowest)
	MaxConcurrent  int           // Max concurrent transcodes (default: 1)
}

// DefaultHLSConfig returns sensible defaults for NAS transcoding.
func DefaultHLSConfig() HLSConfig {
	return HLSConfig{
		SegmentSeconds: 4,
		VideoPreset:    "faster",
		VideoCRF:       23,
		AudioBitrate:   "192k",
		Threads:        2,
		NicePriority:   19,
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

// HLSSession represents an active transcoding session.
type HLSSession struct {
	SessionID    string
	VideoPath    string
	OutputDir    string
	Mode         PlaybackMode
	StartedAt    time.Time
	CompletedAt  *time.Time
	LastAccess   time.Time
	Error        error
	cmd          *exec.Cmd
	cancel       context.CancelFunc
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
func (g *HLSGenerator) StartSession(ctx context.Context, sessionID, videoPath string, mode PlaybackMode) (*HLSSession, error) {
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
	ctx, cancel := context.WithCancel(ctx)
	session := &HLSSession{
		SessionID:  sessionID,
		VideoPath:  videoPath,
		OutputDir:  outputDir,
		Mode:       mode,
		StartedAt:  time.Now(),
		LastAccess: time.Now(),
		cancel:     cancel,
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
		g.active--
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

	delete(g.sessions, sessionID)
	g.mu.Unlock()

	// Clean up output directory
	return os.RemoveAll(session.OutputDir)
}

// runTranscode executes the FFmpeg command for transcoding.
func (g *HLSGenerator) runTranscode(ctx context.Context, session *HLSSession) error {
	if g.config.FFmpegPath == "" {
		return fmt.Errorf("ffmpeg not found")
	}

	// Build FFmpeg arguments based on mode
	args := g.buildFFmpegArgs(session)

	// Create command with nice priority
	var cmd *exec.Cmd
	if g.config.NicePriority > 0 {
		// Use nice for lower priority
		niceArgs := []string{"-n", fmt.Sprintf("%d", g.config.NicePriority), g.config.FFmpegPath}
		niceArgs = append(niceArgs, args...)
		cmd = exec.CommandContext(ctx, "nice", niceArgs...)
	} else {
		cmd = exec.CommandContext(ctx, g.config.FFmpegPath, args...)
	}

	session.cmd = cmd

	// Capture stderr for logging
	cmd.Stdout = io.Discard

	// Create log file for FFmpeg output
	logPath := filepath.Join(session.OutputDir, "ffmpeg.log")
	logFile, err := os.Create(logPath)
	if err != nil {
		cmd.Stderr = io.Discard
	} else {
		defer logFile.Close()
		cmd.Stderr = logFile
	}

	// Run the command
	if err := cmd.Run(); err != nil {
		// Check if context was cancelled
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return fmt.Errorf("ffmpeg failed: %w", err)
	}

	return nil
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

	// Audio always transcoded to AAC for compatibility
	args = append(args,
		"-c:a", "aac",
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
		"-hls_list_size", "0",           // Include all segments in playlist
		"-hls_segment_type", "fmp4",     // Use fragmented MP4 (better for Apple)
		"-hls_fmp4_init_filename", filepath.Base(initPath),
		"-hls_segment_filename", segmentPath,
		"-hls_playlist_type", "vod",     // VOD playlist (complete)
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
