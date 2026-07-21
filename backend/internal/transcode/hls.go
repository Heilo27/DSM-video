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
	"syscall"
	"time"
)

// defaultTranscodeMaxHeight is the resolution ceiling applied to FullTranscode
// sessions that arrive with no explicit quality cap (maxHeight == 0). 720p is the
// most a 4-core/3.8GB software-only NAS can sustain at realtime on a single
// libx264 rung. It also guards against upscaling: the single-variant scale filter
// is scale=-2:min(ih,720), so a sub-720p source keeps its native height. See the
// ABR-disable note in StartSession for why ABR (which had a 1080p upscaling rung)
// was retired on this hardware.
const defaultTranscodeMaxHeight = 720

// ABRVariant describes one rung of the adaptive bitrate ladder.
type ABRVariant struct {
	Height     int    // Max output height in pixels (e.g. 480, 720, 1080)
	Bitrate    string // Target video bitrate (e.g. "800k", "2M", "4M")
	MaxBitrate string // Max bitrate for VBV buffer (e.g. "1200k", "3M", "6M")
	CRF        int    // x264 CRF for this rung
	Name       string // Playlist filename stem (e.g. "v480p")
}

// DefaultABRLadder is the NAS-optimised three-rung ladder.
// Bitrates are conservative to remain real-time on limited NAS CPUs.
var DefaultABRLadder = []ABRVariant{
	{Height: 480, Bitrate: "800k", MaxBitrate: "1200k", CRF: 26, Name: "v480p"},
	{Height: 720, Bitrate: "2000k", MaxBitrate: "3000k", CRF: 24, Name: "v720p"},
	{Height: 1080, Bitrate: "4000k", MaxBitrate: "6000k", CRF: 23, Name: "v1080p"},
}

// HLSConfig contains configuration for HLS generation.
type HLSConfig struct {
	FFmpegPath     string       // Path to ffmpeg binary
	TempDir        string       // Base directory for transcode output
	SegmentSeconds int          // HLS segment duration (default: 6)
	VideoPreset    string       // x264 preset (default: "faster")
	VideoCRF       int          // x264 CRF quality (default: 23)
	AudioBitrate   string       // Audio bitrate (default: "192k")
	Threads        int          // Number of threads (default: 2)
	NicePriority   int          // Nice priority (default: 10 = medium-low; 19 = lowest possible)
	MaxConcurrent  int          // Max concurrent transcodes (default: 1)
	ABRLadder      []ABRVariant // Variants for adaptive bitrate (nil = single-variant)

	// HWAccel selects the hardware encode path: "auto" (detect, fall back to
	// software), "vaapi", "qsv", or "off". TASK-729: on Synology Intel NAS, VAAPI/QSV
	// offloads H.264 encoding to the iGPU — ~5-10x less CPU than libx264, enabling
	// simultaneous streams. Applies to the single-variant transcode path only; the
	// ABR ladder stays on libx264 (multi-rung GPU scaling is unreliable across
	// ffmpeg builds). Empty = "auto".
	HWAccel string
	// VAAPIDevice is the DRM render node for VAAPI (default "/dev/dri/renderD128").
	VAAPIDevice string
}

// DefaultHLSConfig returns sensible defaults for NAS transcoding.
func DefaultHLSConfig() HLSConfig {
	return HLSConfig{
		SegmentSeconds: 6,
		VideoPreset:    "faster",
		VideoCRF:       23,
		AudioBitrate:   "192k",
		Threads:        2,
		NicePriority:   10,
		MaxConcurrent:  1,
		ABRLadder:      DefaultABRLadder,
	}
}

// HLSGenerator handles HLS segment generation.
type HLSGenerator struct {
	config HLSConfig

	// hwEncoder is the resolved hardware encoder family ("vaapi", "qsv", or "" for
	// software). Determined once at construction from config.HWAccel + ffmpeg probe.
	hwEncoder string

	// limiter is the SHARED, process-wide ffmpeg admission budget (TASK-752). Every
	// ffmpeg launch from this generator — the main transcode pass AND the per-track
	// subtitle conversion passes — acquires a slot here so HLS work is counted in the
	// same budget as trickplay. The g.active/MaxConcurrent accounting above still
	// governs HLS *session* admission (and idle-session eviction); the limiter governs
	// actual *ffmpeg process* concurrency across all subsystems. May be nil in tests.
	limiter *FFmpegLimiter

	mu       sync.Mutex
	active   int                    // Number of active transcodes
	sessions map[string]*HLSSession // Active HLS sessions
}

// SetFFmpegLimiter injects the shared ffmpeg admission budget. Called once at
// startup (see main) so HLS, trickplay, and subtitle conversion all draw from one
// pool. Safe to call with nil to disable shared limiting (tests).
func (g *HLSGenerator) SetFFmpegLimiter(l *FFmpegLimiter) {
	g.limiter = l
}

// SubtitleTrack describes a subtitle source (external sidecar or embedded text
// stream) to include in HLS output and expose to the client.
type SubtitleTrack struct {
	Language string  // BCP-47 language tag, e.g. "en", "fr"
	Name     string  // Display name, e.g. "English"
	Path     string  // Absolute path to source SRT/ASS/VTT file ("" for un-extracted image subs)
	Offset   float64 // Timing offset in seconds (positive = delay, negative = advance)

	// Classification (TASK-826). Type is one of "full", "forced", or "image".
	//   - "full":   complete dialogue. Manual toggle, DEFAULT OFF, never auto-enables.
	//   - "forced": translation-only (foreign dialogue in an otherwise-native film).
	//               May auto-enable when it matches the audio language.
	//   - "image":  PGS/VobSub bitmap sub. Out of scope — surfaced but never extracted.
	Type    string
	Forced  bool // disposition.forced OR ".forced" filename token OR cue-density heuristic
	Default bool // disposition.default OR ".default" filename token
	// AutoEnable is set on AT MOST ONE forced track per item — the best forced track
	// whose language matches the primary audio language. Full subs never auto-enable.
	AutoEnable bool
}

// HLSSession represents an active transcoding session.
type HLSSession struct {
	SessionID          string
	VideoPath          string
	OutputDir          string
	Mode               PlaybackMode
	MaxHeight          int
	UseABR             bool // true when multi-variant ABR ladder is active
	SubtitleTracks     []SubtitleTrack
	StartedAt          time.Time
	CompletedAt        *time.Time
	LastAccess         time.Time
	Error              error
	cmd                *exec.Cmd
	cancel             context.CancelFunc
	stopped            bool // true when StopSession has already decremented g.active
	forceSoftware      bool // TASK-729: set on HW-failure retry to force the libx264 path
	forceRemuxReencode bool // set on RemuxOnly copy-failure retry to force the libx264 re-encode path
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

	if config.VAAPIDevice == "" {
		config.VAAPIDevice = "/dev/dri/renderD128"
	}

	g := &HLSGenerator{
		config:   config,
		sessions: make(map[string]*HLSSession),
	}
	g.hwEncoder = g.resolveHWEncoder()
	if g.hwEncoder != "" {
		log.Printf("[HLS] hardware encoding enabled: %s (device %s)", g.hwEncoder, config.VAAPIDevice)
	} else {
		log.Printf("[HLS] hardware encoding disabled — using software libx264")
	}
	return g
}

// resolveHWEncoder decides which hardware encoder to use based on config.HWAccel
// and what the ffmpeg binary actually supports. Returns "vaapi", "qsv", or "".
func (g *HLSGenerator) resolveHWEncoder() string {
	mode := strings.ToLower(strings.TrimSpace(g.config.HWAccel))
	if mode == "" {
		mode = "auto"
	}
	if mode == "off" || g.config.FFmpegPath == "" {
		return ""
	}

	available := g.availableEncoders()
	supports := func(name string) bool { return available[name] }

	switch mode {
	case "vaapi":
		if supports("h264_vaapi") && g.vaapiDevicePresent() {
			return "vaapi"
		}
		return ""
	case "qsv":
		if supports("h264_qsv") {
			return "qsv"
		}
		return ""
	case "auto":
		// Prefer QSV (newer Intel SKUs, simpler pipeline) then VAAPI.
		if supports("h264_qsv") {
			return "qsv"
		}
		if supports("h264_vaapi") && g.vaapiDevicePresent() {
			return "vaapi"
		}
		return ""
	default:
		return ""
	}
}

// availableEncoders runs `ffmpeg -hide_banner -encoders` and returns the set of
// encoder names present in the binary. Best-effort: on any error returns empty.
func (g *HLSGenerator) availableEncoders() map[string]bool {
	out := map[string]bool{}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, g.config.FFmpegPath, "-hide_banner", "-encoders")
	data, err := cmd.Output()
	if err != nil {
		return out
	}
	for _, enc := range []string{"h264_vaapi", "h264_qsv"} {
		if strings.Contains(string(data), enc) {
			out[enc] = true
		}
	}
	return out
}

// vaapiDevicePresent reports whether the configured DRM render node exists.
func (g *HLSGenerator) vaapiDevicePresent() bool {
	if _, err := os.Stat(g.config.VAAPIDevice); err != nil {
		return false
	}
	return true
}

// StartSession begins a new HLS transcoding session.
// It returns immediately and generates HLS segments in the background.
// maxHeight caps the output resolution (0 = no cap; only applies to FullTranscode).
// subtitles lists external subtitle files to convert and embed as HLS renditions.
func (g *HLSGenerator) StartSession(ctx context.Context, sessionID, videoPath string, mode PlaybackMode, maxHeight int, subtitles []SubtitleTrack) (*HLSSession, error) {
	g.mu.Lock()

	// Check if session already exists (re-open of the same title). Do this BEFORE
	// the concurrency check so resuming an existing session never reports "busy".
	if existing, ok := g.sessions[sessionID]; ok {
		existing.LastAccess = time.Now()
		g.mu.Unlock()
		return existing, nil
	}

	// Check if we've hit the concurrent limit. If so, try to reclaim a slot from
	// the most-idle session: an HLS transcode holds its slot for the whole title,
	// so a client that navigated away without sending Stop would otherwise block
	// all new playback forever. Evict the oldest session idle past the grace window.
	if g.active >= g.config.MaxConcurrent {
		victimID := ""
		var oldest time.Time
		for id, s := range g.sessions {
			if s.LastAccess.Before(oldest) || victimID == "" {
				oldest = s.LastAccess
				victimID = id
			}
		}
		const idleGrace = 20 * time.Second
		if victimID != "" && time.Since(oldest) > idleGrace {
			g.mu.Unlock()
			// StopSession takes the lock itself; call it outside our hold.
			_ = g.StopSession(victimID)
			g.mu.Lock()
		}
		// Re-check after the eviction attempt.
		if g.active >= g.config.MaxConcurrent {
			g.mu.Unlock()
			return nil, fmt.Errorf("maximum concurrent transcodes reached (%d)", g.config.MaxConcurrent)
		}
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

	// ABR is DISABLED. Confirmed live on the NAS (smoke test, 2026-06): the
	// multi-variant fMP4 HLS muxer crashes on FullTranscode inputs whose video
	// codec is not h264/hevc (e.g. mpeg4/XVID AVI, ~395 items in the library).
	// The 3-rung ladder feeds one mpeg4 stream through `split -> libx264 ×3` and
	// the muxer fails the var_stream_map header write:
	//   [hls] Variant stream info update failed with status ffffffea
	//   [out#0/hls] Could not write header (incorrect codec parameters ?)
	//   Conversion failed!  -> 0 segments, no master.m3u8, client 503.
	// The ABR path also has NO copy/hw->software fallback (unlike single-variant),
	// so the session just dies. And the ladder was never realistic on this 4-core
	// /3.8GB software-only NAS anyway — three concurrent libx264 rungs (one of
	// which UPSCALES low-res sources to 1080p) can't sustain realtime here.
	//
	// Fix: force every session through the robust single-variant path — the same
	// proven muxer config RemuxOnly and quality-capped transcodes already use. The
	// ABR code (buildABRArgs / writeMasterPlaylist) is left in place but unreached
	// so a future hardware-accelerated box can re-enable it.
	useABR := false

	// For FullTranscode sessions that previously would have gone ABR (no explicit
	// quality cap, maxHeight == 0), apply a NAS-appropriate 720p ceiling so the
	// single-variant path scales down to 720p max. The scale filter is
	// `scale=-2:min(ih,720)`, so a 360p source is NOT upscaled (min picks 360) and
	// a 1080p source is downscaled to 720 — a 4-core software-only NAS can sustain
	// a single 720p libx264 rung where it could not sustain the ABR ladder.
	// Only FullTranscode is capped; RemuxOnly/copy and DirectPlay are untouched.
	if mode == FullTranscode && maxHeight == 0 {
		maxHeight = defaultTranscodeMaxHeight
	}

	session := &HLSSession{
		SessionID:      sessionID,
		VideoPath:      videoPath,
		OutputDir:      outputDir,
		Mode:           mode,
		MaxHeight:      maxHeight,
		UseABR:         useABR,
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

	// Kill the whole process group (negative PID). ctx cancel only reaches the
	// direct child; the `nice`-wrapped ffmpeg grandchild needs an explicit group
	// kill or it leaks until the cleanup tick. SIGKILL because we're tearing down.
	if session.cmd != nil && session.cmd.Process != nil {
		if pgid, err := syscall.Getpgid(session.cmd.Process.Pid); err == nil {
			_ = syscall.Kill(-pgid, syscall.SIGKILL)
		} else {
			// Fall back to killing just the process if the group lookup failed.
			_ = session.cmd.Process.Kill()
		}
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

	// Clean up output directory. ffmpeg may still hold segment files for a beat
	// after the kill signal on slow NAS I/O, so retry briefly rather than leaking
	// the temp dir on the first EBUSY/ENOTEMPTY.
	var rmErr error
	for attempt := 0; attempt < 5; attempt++ {
		if rmErr = os.RemoveAll(session.OutputDir); rmErr == nil {
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	return rmErr
}

// runFFmpegOnce builds and runs a single ffmpeg invocation for the session with
// the given args, in its own process group, capturing stderr to ffmpeg.log.
func (g *HLSGenerator) runFFmpegOnce(ctx context.Context, session *HLSSession, args []string) error {
	// TASK-752: acquire a slot in the SHARED ffmpeg budget before spawning the
	// process. This is the only place an HLS ffmpeg process is actually launched
	// (both the initial pass and the HW-failure software retry route through here),
	// so it's the right choke point. Live playback uses the blocking Acquire — it
	// always eventually gets a slot — while trickplay yields (see generateTrickplayOnce).
	// Acquire is context-aware so a cancelled playback won't deadlock waiting on a
	// saturated budget. The slot is held for the full ffmpeg run and released on exit.
	if err := g.limiter.Acquire(ctx); err != nil {
		return err
	}
	defer g.limiter.Release()

	var cmd *exec.Cmd
	if g.config.NicePriority > 0 {
		niceArgs := []string{"-n", fmt.Sprintf("%d", g.config.NicePriority), g.config.FFmpegPath}
		niceArgs = append(niceArgs, args...)
		cmd = exec.CommandContext(ctx, "nice", niceArgs...)
	} else {
		cmd = exec.CommandContext(ctx, g.config.FFmpegPath, args...)
	}

	// Run ffmpeg (and the `nice` wrapper, when used) in its own process group so
	// StopSession can kill the entire group. exec.CommandContext only signals the
	// direct child on ctx cancel — when wrapped in `nice`, ffmpeg is a grandchild
	// and would otherwise survive as an orphan until the 5-minute cleanup tick.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	// Publish session.cmd under g.mu: StopSession reads it under the same lock to kill
	// the process group. The playSessions reaper and the /playback/{id}/stop endpoint
	// (TASK-754) can now call StopSession at any time, so this write must be
	// synchronized — an unguarded write here races the locked read in StopSession.
	g.mu.Lock()
	session.cmd = cmd
	g.mu.Unlock()
	cmd.Stdout = io.Discard

	logPath := filepath.Join(session.OutputDir, "ffmpeg.log")
	logFile, err := os.Create(logPath)
	if err != nil {
		cmd.Stderr = io.Discard
	} else {
		defer logFile.Close()
		cmd.Stderr = logFile
	}

	return cmd.Run()
}

// runTranscode executes the FFmpeg command for transcoding, then converts any
// subtitle tracks to WebVTT and rewrites the master playlist to reference them.
func (g *HLSGenerator) runTranscode(ctx context.Context, session *HLSSession) error {
	if g.config.FFmpegPath == "" {
		return fmt.Errorf("ffmpeg not found")
	}

	runErr := g.runFFmpegOnce(ctx, session, g.buildFFmpegArgs(session))
	if runErr != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		// TASK-729: if a hardware-encoded transcode failed at runtime (driver/surface
		// issue that startup detection couldn't catch), retry once on software so the
		// stream still plays. forceSoftware disables the HW path for this rebuild.
		if g.hwEncoder != "" && session.Mode == FullTranscode && !session.UseABR {
			log.Printf("[HLS] hardware transcode failed (%v) — retrying on software libx264", runErr)
			session.forceSoftware = true
			if err := os.RemoveAll(session.OutputDir); err == nil {
				_ = os.MkdirAll(session.OutputDir, 0o755)
			}
			runErr = g.runFFmpegOnce(ctx, session, g.buildFFmpegArgs(session))
		} else if session.Mode == RemuxOnly && !session.forceRemuxReencode {
			// The RemuxOnly copy path (-c:v copy + timestamp repair) failed. This is the
			// rare genuinely-broken-DTS file the +igndts repair couldn't salvage. Retry
			// once with the proven full libx264 re-encode, which regenerates clean
			// timestamps from scratch. Mutually exclusive with the HW retry above
			// (different Mode), so at most one fallback per failure.
			log.Printf("[HLS] remux copy failed (%v) — retrying with re-encode", runErr)
			session.forceRemuxReencode = true
			if err := os.RemoveAll(session.OutputDir); err == nil {
				_ = os.MkdirAll(session.OutputDir, 0o755)
			}
			runErr = g.runFFmpegOnce(ctx, session, g.buildFFmpegArgs(session))
		}
	}
	if runErr != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return fmt.Errorf("ffmpeg failed: %w", runErr)
	}

	// For ABR sessions ffmpeg writes per-variant playlists but its auto-generated
	// master may not have BANDWIDTH values we want. Overwrite with ours.
	if session.UseABR {
		if err := g.writeMasterPlaylist(session); err != nil {
			log.Printf("[HLS] ABR writeMasterPlaylist failed: %v", err)
		}
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
		// Image-based subs (PGS/VobSub) are out of scope: no text to convert to WebVTT
		// and no source path to feed ffmpeg. They're surfaced in the /playback response
		// as type:"image" but produce no HLS rendition. Skip them here.
		if sub.Type == "image" || sub.Path == "" {
			continue
		}
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

		// TASK-752: subtitle conversion is also an ffmpeg pass and was previously
		// ungated entirely — it could push total ffmpeg processes past the budget
		// while a transcode was running. Draw from the shared limiter like everything
		// else. These passes run after the main transcode for the same session, so a
		// blocking Acquire is fine (the session already proved it can get a slot).
		if err := g.limiter.Acquire(ctx); err != nil {
			log.Printf("[HLS] subtitle convert aborted (track %d %s): %v", i, sub.Language, err)
			return
		}
		subCmd := exec.CommandContext(ctx, g.config.FFmpegPath, ffArgs...)
		subCmd.Stdout = io.Discard
		subCmd.Stderr = io.Discard
		err := subCmd.Run()
		g.limiter.Release()
		if err != nil {
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
		// DEFAULT=YES marks the rendition a compliant player selects automatically.
		// We map it to the auto-enable decision (the single best forced track matching
		// the audio language) rather than "first track". FORCED=YES advertises the
		// rendition as containing only forced/translation cues so players may show it
		// even when the user has subtitles off.
		isDefault := "NO"
		if sub.AutoEnable {
			isDefault = "YES"
		}
		isForced := "NO"
		if sub.Forced {
			isForced = "YES"
		}
		renditionLines = append(renditionLines,
			fmt.Sprintf(`#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",LANGUAGE="%s",NAME="%s",DEFAULT=%s,FORCED=%s,URI="%s"`,
				lang, name, isDefault, isForced, vttName),
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
	if session.UseABR {
		return g.buildABRArgs(session)
	}
	return g.buildSingleVariantArgs(session)
}

// buildSingleVariantArgs builds args for the original single-quality HLS output.
func (g *HLSGenerator) buildSingleVariantArgs(session *HLSSession) []string {
	outputPath := filepath.Join(session.OutputDir, "master.m3u8")
	segmentPath := filepath.Join(session.OutputDir, "segment_%05d.m4s")
	initPath := filepath.Join(session.OutputDir, "init.mp4")

	// HW init flags (e.g. VAAPI device) must precede -i, so build a prefix.
	useHW := session.Mode == FullTranscode && g.hwEncoder != "" && !session.forceSoftware
	var pre []string
	if useHW && g.hwEncoder == "vaapi" {
		pre = append(pre,
			"-vaapi_device", g.config.VAAPIDevice,
		)
	}

	// -fflags +genpts regenerates presentation timestamps for sources with missing
	// or broken PTS. Combined with -avoid_negative_ts on the output, this keeps the
	// fMP4 muxer from emitting segments with corrupt timing.
	//
	// On the RemuxOnly copy path we additionally need +igndts: those H.264-in-MKV
	// sources can carry non-monotonic / duplicate DTS in the elementary stream, and a
	// bare -c:v copy would carry that broken timing into the fMP4 segments (AVPlayer
	// rejects them as "resource unavailable"). +igndts makes the demuxer drop the
	// source DTS, +genpts regenerates PTS, and -avoid_negative_ts make_zero on the
	// output normalizes the muxed timestamps — clean monotonic timing WITHOUT a
	// re-encode. The forced re-encode fallback keeps plain +genpts (libx264 emits its
	// own timestamps, so igndts buys nothing there).
	fflags := "+genpts"
	if session.Mode == RemuxOnly && !session.forceRemuxReencode {
		fflags = "+genpts+igndts"
	}
	args := []string{"-y", "-fflags", fflags}
	args = append(args, pre...)
	args = append(args, "-i", session.VideoPath)

	// Resolved encoder for this run — empty when software (incl. a forced retry).
	enc := ""
	if useHW {
		enc = g.hwEncoder
	}

	switch session.Mode {
	case RemuxOnly:
		// RemuxOnly sources are already Apple-compatible H.264-in-MKV — the whole point
		// of this mode is to NOT re-encode the video, just transcode incompatible audio.
		// So the primary path is "-c:v copy" combined with muxer-level timestamp repair
		// (input -fflags +genpts+igndts, output -avoid_negative_ts make_zero — see the
		// fflags comment above and the audio/mux tail). Copy + repair starts playback in
		// ~1-2s instead of the ~0.4x-realtime libx264 re-encode that was timing out the
		// client's WaitForPlaylist window on the 4-core software-only NAS.
		//
		// HISTORY: an earlier fix used a full libx264 re-encode here because a bare
		// -c:v copy preserved the broken (non-monotonic / duplicate) DTS some of these
		// MKVs carry, producing fMP4 segments AVPlayer rejected as "resource
		// unavailable". The +igndts demuxer flag now drops that bad DTS so copy is safe
		// for the common case. For the rare genuinely-broken file where copy still
		// fails, runTranscode sets forceRemuxReencode and re-runs THIS branch through the
		// libx264 fallback below — so we keep the proven re-encode as a per-file safety
		// net without paying its cost on the ~302 files that copy just fine.
		//
		// hwEncoder is intentionally ignored here: RemuxOnly exists to avoid encoding,
		// so even when a HW encoder is present we copy. Encoding (HW or SW) only happens
		// on the forced fallback.
		if session.forceRemuxReencode {
			args = append(args,
				"-c:v", "libx264",
				"-preset", g.config.VideoPreset,
				"-crf", fmt.Sprintf("%d", g.config.VideoCRF),
				"-threads", fmt.Sprintf("%d", g.config.Threads),
				"-pix_fmt", "yuv420p",
			)
		} else {
			args = append(args, "-c:v", "copy")
		}
	case FullTranscode:
		switch {
		case enc == "vaapi":
			// Upload to GPU surfaces, optionally scale on the GPU, encode with VAAPI.
			vf := "format=nv12,hwupload"
			if session.MaxHeight > 0 {
				vf = fmt.Sprintf("scale_vaapi=w=-2:h='min(ih\\,%d)':format=nv12", session.MaxHeight)
				vf = "format=nv12|vaapi,hwupload," + vf
			}
			args = append(args,
				"-vf", vf,
				"-c:v", "h264_vaapi",
				"-qp", fmt.Sprintf("%d", g.config.VideoCRF),
			)
		case enc == "qsv":
			if session.MaxHeight > 0 {
				args = append(args, "-vf", fmt.Sprintf("scale=-2:min(ih\\,%d)", session.MaxHeight))
			}
			args = append(args,
				"-c:v", "h264_qsv",
				"-global_quality", fmt.Sprintf("%d", g.config.VideoCRF),
				"-pix_fmt", "nv12",
			)
		default:
			if session.MaxHeight > 0 {
				args = append(args,
					"-vf", fmt.Sprintf("scale=-2:min(ih\\,%d)", session.MaxHeight),
				)
			}
			args = append(args,
				"-c:v", "libx264",
				"-preset", g.config.VideoPreset,
				"-crf", fmt.Sprintf("%d", g.config.VideoCRF),
				"-threads", fmt.Sprintf("%d", g.config.Threads),
				"-pix_fmt", "yuv420p",
			)
		}
	default:
		args = append(args, "-c:v", "copy")
	}

	args = append(args,
		"-map", "0:v:0",
		"-map", "0:a:0?",
		// AAC, not MP3: fMP4/CMAF segments expect AAC audio, and MP3-in-fMP4 is a
		// second source of "resource unavailable" on some players. AAC is also what
		// Apple devices want natively.
		"-c:a", "aac",
		"-b:a", g.config.AudioBitrate,
		"-ac", "2",
		// Normalize start timestamps so the first segment doesn't carry negative ts.
		"-avoid_negative_ts", "make_zero",
	)

	segDur := g.config.SegmentSeconds
	if segDur == 0 {
		segDur = 6
	}

	args = append(args,
		"-f", "hls",
		"-hls_time", fmt.Sprintf("%d", segDur),
		"-hls_list_size", "0",
		"-hls_segment_type", "fmp4",
		"-hls_fmp4_init_filename", filepath.Base(initPath),
		"-hls_segment_filename", segmentPath,
		"-hls_flags", "independent_segments",
		outputPath,
	)

	return args
}

// buildABRArgs builds args for a multi-variant ABR HLS output using a single
// ffmpeg pass with filter_complex + var_stream_map. ffmpeg's HLS muxer writes
// one variant playlist per stream group; we write master.m3u8 ourselves after.
//
// ffmpeg command shape:
//
//	ffmpeg -i input \
//	  -filter_complex "[0:v]split=3[vin0][vin1][vin2];[vin0]scale=-2:480[v0];..." \
//	  -map [v0] -c:v:0 libx264 -crf:0 26 -b:v:0 800k ... \
//	  -map [v1] -c:v:1 libx264 -crf:1 24 -b:v:1 2000k ... \
//	  -map [v2] -c:v:2 libx264 -crf:2 23 -b:v:2 4000k ... \
//	  -map 0:a:0? -c:a libmp3lame -b:a 192k -ac 2 \
//	  -f hls -hls_time 6 -hls_segment_type fmp4 \
//	  -var_stream_map "v:0,a:0 v:1,a:0 v:2,a:0" \
//	  -master_pl_name master_ffmpeg.m3u8 \
//	  -hls_segment_filename <dir>/v%v_%05d.m4s \
//	  <dir>/v%v.m3u8
func (g *HLSGenerator) buildABRArgs(session *HLSSession) []string {
	ladder := g.config.ABRLadder
	segDur := g.config.SegmentSeconds
	if segDur == 0 {
		segDur = 6
	}
	threads := g.config.Threads
	n := len(ladder)

	args := []string{"-y", "-fflags", "+genpts", "-i", session.VideoPath}

	// filter_complex: split + scale each rung
	splitOut := ""
	for i := range ladder {
		splitOut += fmt.Sprintf("[vin%d]", i)
	}
	filter := fmt.Sprintf("[0:v]split=%d%s", n, splitOut)
	for i, v := range ladder {
		filter += fmt.Sprintf(";[vin%d]scale=-2:%d[v%d]", i, v.Height, i)
	}
	args = append(args, "-filter_complex", filter)

	// Per-variant video codec args
	for i, v := range ladder {
		args = append(args,
			"-map", fmt.Sprintf("[v%d]", i),
			fmt.Sprintf("-c:v:%d", i), "libx264",
			fmt.Sprintf("-preset:%d", i), g.config.VideoPreset,
			fmt.Sprintf("-crf:%d", i), fmt.Sprintf("%d", v.CRF),
			fmt.Sprintf("-b:v:%d", i), v.Bitrate,
			fmt.Sprintf("-maxrate:%d", i), v.MaxBitrate,
			fmt.Sprintf("-bufsize:%d", i), v.MaxBitrate,
			fmt.Sprintf("-threads:%d", i), fmt.Sprintf("%d", threads),
			fmt.Sprintf("-pix_fmt:%d", i), "yuv420p",
		)
	}

	// Single audio stream shared across all variants. AAC (not MP3) — fMP4/CMAF
	// segments expect AAC and it's what Apple devices play natively.
	args = append(args,
		"-map", "0:a:0?",
		"-c:a", "aac",
		"-b:a", g.config.AudioBitrate,
		"-ac", "2",
		"-avoid_negative_ts", "make_zero",
	)

	// var_stream_map tells ffmpeg which video+audio streams form each variant group
	var vsm []string
	for i := range ladder {
		vsm = append(vsm, fmt.Sprintf("v:%d,a:0", i))
	}

	segPattern := filepath.Join(session.OutputDir, "v%v_%05d.m4s")
	playlistPattern := filepath.Join(session.OutputDir, "v%v.m3u8")

	args = append(args,
		"-f", "hls",
		"-hls_time", fmt.Sprintf("%d", segDur),
		"-hls_list_size", "0",
		"-hls_segment_type", "fmp4",
		// Use %v (variant index) in filenames so ffmpeg writes per-variant files.
		"-hls_fmp4_init_filename", "v%v_init.mp4",
		"-hls_segment_filename", segPattern,
		"-hls_flags", "independent_segments",
		"-var_stream_map", strings.Join(vsm, " "),
		// ffmpeg writes its own master — we overwrite it with ours after the pass.
		"-master_pl_name", "master_ffmpeg.m3u8",
		playlistPattern,
	)

	return args
}

// writeMasterPlaylist generates master.m3u8 referencing all ABR variant playlists.
// ffmpeg names them v0.m3u8, v1.m3u8, … matching the %v pattern in buildABRArgs.
// Called after the ffmpeg ABR pass completes successfully.
func (g *HLSGenerator) writeMasterPlaylist(session *HLSSession) error {
	var sb strings.Builder
	sb.WriteString("#EXTM3U\n")
	sb.WriteString("#EXT-X-VERSION:6\n\n")

	for i, v := range g.config.ABRLadder {
		bps := parseBitrate(v.Bitrate)
		// ffmpeg %v substitution uses the variant index, not the Name field.
		sb.WriteString(fmt.Sprintf(
			"#EXT-X-STREAM-INF:BANDWIDTH=%d,RESOLUTION=x%d,CODECS=\"avc1.42e01e,mp4a.40.2\"\nv%d.m3u8\n",
			bps, v.Height, i,
		))
	}

	masterPath := filepath.Join(session.OutputDir, "master.m3u8")
	return os.WriteFile(masterPath, []byte(sb.String()), 0644)
}

// parseBitrate converts a bitrate string like "800k" or "4M" to integer bps.
func parseBitrate(s string) int {
	if len(s) == 0 {
		return 0
	}
	suffix := s[len(s)-1]
	num := s[:len(s)-1]
	var n int
	fmt.Sscanf(num, "%d", &n)
	switch suffix {
	case 'k', 'K':
		return n * 1000
	case 'm', 'M':
		return n * 1_000_000
	default:
		var full int
		fmt.Sscanf(s, "%d", &full)
		return full
	}
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
	SessionID    string
	Mode         string
	StartedAt    time.Time
	CompletedAt  *time.Time
	LastAccess   time.Time
	Error        string
	SegmentCount int
	OutputSizeKB int64
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
