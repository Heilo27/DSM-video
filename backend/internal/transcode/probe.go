// Package transcode provides video transcoding capabilities for DS Video.
// It detects codec information and generates HLS streams for playback
// on Apple devices that don't support certain containers or codecs.
package transcode

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Chapter represents a single chapter entry from a video file.
type Chapter struct {
	ID        int     `json:"id"`
	Title     string  `json:"title"`
	StartSecs float64 `json:"startSecs"`
	EndSecs   float64 `json:"endSecs"`
}

// ProbeResult contains the codec and container information for a video file.
type ProbeResult struct {
	Container      string    // e.g., "mp4", "mkv", "webm", "mov"
	VideoCodec     string    // e.g., "h264", "hevc", "vp9", "av1"
	AudioCodec     string    // e.g., "aac", "ac3", "dts", "eac3", "flac", "opus"
	DurationSecs   float64   // Duration in seconds
	Width          int       // Video width
	Height         int       // Video height
	AudioChannels  int       // Channel count of the primary audio stream (e.g. 2, 6, 8)
	Bitrate        int64     // Overall bitrate in bps
	NeedsTranscode bool      // Pre-computed flag for whether transcoding is needed
	Chapters       []Chapter // Chapter list (may be empty)
	EmbeddedSubs   []EmbeddedSubtitle // Text-based embedded subtitle streams (may be empty)
}

// EmbeddedSubtitle describes a text subtitle stream muxed inside the container
// (e.g. an MKV with internal SRT/ASS). Image-based subs (PGS/VobSub) are excluded
// since they can't be converted to WebVTT without OCR.
type EmbeddedSubtitle struct {
	Index    int    // ffmpeg stream index
	Language string // BCP-47-ish tag from stream tags (e.g. "en"), or "und"
	Title    string // Optional human title from stream tags
	Codec    string // e.g. "subrip", "ass", "mov_text"
	Forced   bool
	Default  bool
}

// ffprobeOutput represents the JSON output from ffprobe.
type ffprobeOutput struct {
	Format struct {
		FormatName string `json:"format_name"`
		Duration   string `json:"duration"`
		BitRate    string `json:"bit_rate"`
		FormatLong string `json:"format_long_name"`
	} `json:"format"`
	Streams []struct {
		Index      int               `json:"index"`
		CodecType  string            `json:"codec_type"`
		CodecName  string            `json:"codec_name"`
		Width      int               `json:"width,omitempty"`
		Height     int               `json:"height,omitempty"`
		Channels   int               `json:"channels,omitempty"`
		SampleRate string            `json:"sample_rate,omitempty"`
		Tags       map[string]string `json:"tags,omitempty"`
		Disposition struct {
			Default int `json:"default"`
			Forced  int `json:"forced"`
		} `json:"disposition,omitempty"`
	} `json:"streams"`
	Chapters []struct {
		ID        int               `json:"id"`
		StartTime string            `json:"start_time"`
		EndTime   string            `json:"end_time"`
		Tags      map[string]string `json:"tags"`
	} `json:"chapters"`
}

// Prober handles video probing with configurable ffprobe path.
type Prober struct {
	FFprobePath string
}

// NewProber creates a new Prober with the given ffprobe path.
// If path is empty, it will search for ffprobe in PATH.
func NewProber(ffprobePath string) *Prober {
	if ffprobePath == "" {
		// Try to find ffprobe in PATH
		if path, err := exec.LookPath("ffprobe"); err == nil {
			ffprobePath = path
		} else {
			// Common Synology locations
			for _, p := range []string{
				"/usr/bin/ffprobe",
				"/usr/local/bin/ffprobe",
				"/volume1/@appstore/ffmpeg/bin/ffprobe",
				"/var/packages/ffmpeg/target/bin/ffprobe",
			} {
				if _, err := exec.LookPath(p); err == nil {
					ffprobePath = p
					break
				}
			}
		}
	}
	return &Prober{FFprobePath: ffprobePath}
}

// Probe analyzes a video file and returns codec information.
func (p *Prober) Probe(ctx context.Context, path string) (*ProbeResult, error) {
	if p.FFprobePath == "" {
		return nil, fmt.Errorf("ffprobe not found")
	}

	// Set timeout for probe operation
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, p.FFprobePath,
		"-v", "quiet",
		"-print_format", "json",
		"-show_format",
		"-show_streams",
		"-show_chapters",
		path,
	)

	output, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("ffprobe failed: %w", err)
	}

	var probeData ffprobeOutput
	if err := json.Unmarshal(output, &probeData); err != nil {
		return nil, fmt.Errorf("parse ffprobe output: %w", err)
	}

	result := &ProbeResult{}

	// Parse container format
	result.Container = normalizeContainer(probeData.Format.FormatName)

	// Parse duration
	if probeData.Format.Duration != "" {
		fmt.Sscanf(probeData.Format.Duration, "%f", &result.DurationSecs)
	}

	// Parse bitrate
	if probeData.Format.BitRate != "" {
		fmt.Sscanf(probeData.Format.BitRate, "%d", &result.Bitrate)
	}

	// Find video and audio streams
	for _, stream := range probeData.Streams {
		switch stream.CodecType {
		case "video":
			if result.VideoCodec == "" { // Take first video stream
				result.VideoCodec = normalizeVideoCodec(stream.CodecName)
				result.Width = stream.Width
				result.Height = stream.Height
			}
		case "audio":
			if result.AudioCodec == "" { // Take first audio stream
				result.AudioCodec = normalizeAudioCodec(stream.CodecName)
				result.AudioChannels = stream.Channels
			}
		case "subtitle":
			// Only text-based subtitle codecs can be converted to WebVTT. Image-based
			// (hdmv_pgs_subtitle, dvd_subtitle/VobSub) require OCR — skip them.
			switch strings.ToLower(stream.CodecName) {
			case "subrip", "srt", "ass", "ssa", "mov_text", "webvtt", "text":
				sub := EmbeddedSubtitle{
					Index:   stream.Index,
					Codec:   strings.ToLower(stream.CodecName),
					Forced:  stream.Disposition.Forced == 1,
					Default: stream.Disposition.Default == 1,
				}
				sub.Language = "und"
				if l := strings.ToLower(stream.Tags["language"]); l != "" {
					sub.Language = l
				}
				sub.Title = stream.Tags["title"]
				result.EmbeddedSubs = append(result.EmbeddedSubs, sub)
			}
		}
	}

	// Parse chapters
	for i, ch := range probeData.Chapters {
		c := Chapter{ID: ch.ID}
		if title, ok := ch.Tags["title"]; ok && title != "" {
			c.Title = title
		} else {
			c.Title = fmt.Sprintf("Chapter %d", i+1)
		}
		fmt.Sscanf(ch.StartTime, "%f", &c.StartSecs)
		fmt.Sscanf(ch.EndTime, "%f", &c.EndSecs)
		result.Chapters = append(result.Chapters, c)
	}

	// Pre-compute whether transcoding is needed
	result.NeedsTranscode = needsTranscode(result)

	return result, nil
}

// ProbeQuick performs a quick probe using file extension heuristics.
// This is useful when ffprobe is not available or for quick decisions.
func ProbeQuick(path string) *ProbeResult {
	ext := strings.ToLower(filepath.Ext(path))
	result := &ProbeResult{}

	// Infer container from extension
	switch ext {
	case ".mp4", ".m4v":
		result.Container = "mp4"
		result.VideoCodec = "h264" // Assume H.264 for MP4
		result.AudioCodec = "aac"  // Assume AAC for MP4
	case ".mov":
		result.Container = "mov"
		result.VideoCodec = "h264"
		result.AudioCodec = "aac"
	case ".mkv":
		result.Container = "mkv"
		result.VideoCodec = "h264" // Could be anything
		result.AudioCodec = "unknown"
		result.NeedsTranscode = true // MKV likely needs transcoding
	case ".webm":
		result.Container = "webm"
		result.VideoCodec = "vp9"
		result.AudioCodec = "opus"
		result.NeedsTranscode = true
	case ".avi":
		result.Container = "avi"
		result.VideoCodec = "unknown"
		result.AudioCodec = "unknown"
		result.NeedsTranscode = true
	case ".ts":
		result.Container = "ts"
		result.VideoCodec = "h264"
		result.AudioCodec = "aac"
	default:
		result.Container = strings.TrimPrefix(ext, ".")
		result.NeedsTranscode = true
	}

	return result
}

// normalizeContainer standardizes container format names.
func normalizeContainer(format string) string {
	// FFprobe may return multiple formats like "mov,mp4,m4a,3gp,3g2,mj2"
	formats := strings.Split(format, ",")
	first := strings.TrimSpace(formats[0])

	switch first {
	case "matroska":
		return "mkv"
	case "mov":
		return "mov"
	case "mp4":
		return "mp4"
	case "webm":
		return "webm"
	case "avi":
		return "avi"
	case "mpegts":
		return "ts"
	default:
		return first
	}
}

// normalizeVideoCodec standardizes video codec names.
func normalizeVideoCodec(codec string) string {
	codec = strings.ToLower(codec)
	switch codec {
	case "h264", "avc", "avc1":
		return "h264"
	case "h265", "hevc", "hev1":
		return "hevc"
	case "vp9", "vp09":
		return "vp9"
	case "av1", "av01":
		return "av1"
	case "mpeg4", "mp4v":
		return "mpeg4"
	case "mpeg2video":
		return "mpeg2"
	default:
		return codec
	}
}

// normalizeAudioCodec standardizes audio codec names.
func normalizeAudioCodec(codec string) string {
	codec = strings.ToLower(codec)
	switch codec {
	case "aac", "mp4a":
		return "aac"
	case "ac3", "a52":
		return "ac3"
	case "eac3", "ec3":
		return "eac3"
	case "dts", "dca":
		return "dts"
	case "flac":
		return "flac"
	case "opus":
		return "opus"
	case "mp3", "mp3float":
		return "mp3"
	case "vorbis":
		return "vorbis"
	case "pcm_s16le", "pcm_s24le", "pcm_s32le":
		return "pcm"
	default:
		return codec
	}
}

// needsTranscode determines if a file needs transcoding for Apple device playback.
func needsTranscode(result *ProbeResult) bool {
	// Check container compatibility
	containerOK := result.Container == "mp4" || result.Container == "mov" || result.Container == "m4v"

	// Check video codec compatibility (H.264 and HEVC are natively supported)
	videoOK := result.VideoCodec == "h264" || result.VideoCodec == "hevc"

	// Check audio codec compatibility (AAC is the safe option)
	audioOK := result.AudioCodec == "aac"

	return !containerOK || !videoOK || !audioOK
}

// ExtractEmbeddedSubtitle extracts one text subtitle stream from a container to a
// .srt file at destPath using ffmpeg. Returns an error if ffmpeg fails. The output
// is SRT (universally convertible by the existing HLS WebVTT pipeline). Caller is
// responsible for choosing a stable destPath (e.g. in a per-item cache dir) and for
// not re-extracting when the file already exists.
func ExtractEmbeddedSubtitle(ctx context.Context, ffmpegPath, videoPath string, streamIndex int, destPath string) error {
	if ffmpegPath == "" {
		return fmt.Errorf("ffmpeg not found")
	}
	if err := os.MkdirAll(filepath.Dir(destPath), 0o755); err != nil {
		return fmt.Errorf("create subtitle cache dir: %w", err)
	}
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()

	// -map 0:<index> selects the specific subtitle stream; -c:s srt transcodes
	// ass/mov_text/etc to SubRip. -y overwrites a stale partial file.
	cmd := exec.CommandContext(ctx, ffmpegPath,
		"-v", "error",
		"-y",
		"-i", videoPath,
		"-map", fmt.Sprintf("0:%d", streamIndex),
		"-c:s", "srt",
		destPath,
	)
	if out, err := cmd.CombinedOutput(); err != nil {
		// Clean up any partial output so a later run retries cleanly.
		_ = os.Remove(destPath)
		return fmt.Errorf("ffmpeg subtitle extract (stream %d): %w: %s", streamIndex, err, strings.TrimSpace(string(out)))
	}
	return nil
}
