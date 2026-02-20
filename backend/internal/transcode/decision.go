package transcode

// PlaybackMode represents how a video should be played back.
type PlaybackMode int

const (
	// DirectPlay streams the file as-is without any processing.
	// Used when container and codecs are fully compatible with Apple devices.
	DirectPlay PlaybackMode = iota

	// RemuxOnly copies the video stream but transcodes audio to AAC.
	// Used when video codec is compatible but audio needs conversion (AC3/DTS → AAC).
	RemuxOnly

	// FullTranscode transcodes both video and audio streams.
	// Used when video codec is not compatible (VP9/AV1) or container needs complete repackaging.
	FullTranscode
)

// String returns a human-readable name for the playback mode.
func (m PlaybackMode) String() string {
	switch m {
	case DirectPlay:
		return "direct"
	case RemuxOnly:
		return "remux"
	case FullTranscode:
		return "transcode"
	default:
		return "unknown"
	}
}

// NeedsTranscoding returns true if this mode requires FFmpeg processing.
func (m PlaybackMode) NeedsTranscoding() bool {
	return m != DirectPlay
}

// NeedsVideoTranscode returns true if video stream needs to be re-encoded.
func (m PlaybackMode) NeedsVideoTranscode() bool {
	return m == FullTranscode
}

// NeedsAudioTranscode returns true if audio stream needs to be re-encoded.
func (m PlaybackMode) NeedsAudioTranscode() bool {
	return m == RemuxOnly || m == FullTranscode
}

// compatibleContainers are containers that Apple devices can play natively.
var compatibleContainers = map[string]bool{
	"mp4": true,
	"mov": true,
	"m4v": true,
}

// compatibleVideoCodecs are video codecs supported by Apple devices.
var compatibleVideoCodecs = map[string]bool{
	"h264": true,
	"hevc": true,
}

// compatibleAudioCodecs are audio codecs supported by Apple devices.
var compatibleAudioCodecs = map[string]bool{
	"aac": true,
	"mp3": true, // MP3 works but AAC is preferred
}

// DecidePlayback determines the best playback mode based on codec information.
// This implements the three-tier decision logic:
//
//  1. DirectPlay: MP4/MOV + H.264/HEVC + AAC → Stream as-is
//  2. RemuxOnly: MKV + H.264/HEVC + AC3/DTS → Copy video, transcode audio
//  3. FullTranscode: VP9/AV1 or exotic codec → Transcode video + audio
func DecidePlayback(videoCodec, audioCodec, container string) PlaybackMode {
	containerOK := compatibleContainers[container]
	videoOK := compatibleVideoCodecs[videoCodec]
	audioOK := compatibleAudioCodecs[audioCodec]

	// If everything is compatible, direct play
	if containerOK && videoOK && audioOK {
		return DirectPlay
	}

	// If video is compatible but container or audio isn't, we can remux
	// (copy video stream, transcode audio, repackage to fMP4/HLS)
	if videoOK {
		return RemuxOnly
	}

	// Video codec is not compatible, need full transcode
	return FullTranscode
}

// DecidePlaybackFromProbe determines playback mode from a ProbeResult.
func DecidePlaybackFromProbe(probe *ProbeResult) PlaybackMode {
	if probe == nil {
		return FullTranscode // Safe fallback
	}
	return DecidePlayback(probe.VideoCodec, probe.AudioCodec, probe.Container)
}

// PlaybackDecision contains detailed information about the playback decision.
type PlaybackDecision struct {
	Mode              PlaybackMode
	Reason            string
	SourceContainer   string
	SourceVideoCodec  string
	SourceAudioCodec  string
	TargetContainer   string
	TargetVideoCodec  string
	TargetAudioCodec  string
	EstimatedCPULoad  string // "low", "medium", "high"
}

// DecideWithDetails returns a detailed playback decision with reasoning.
func DecideWithDetails(probe *ProbeResult) PlaybackDecision {
	if probe == nil {
		return PlaybackDecision{
			Mode:             FullTranscode,
			Reason:           "No probe information available",
			TargetContainer:  "fmp4/hls",
			TargetVideoCodec: "h264",
			TargetAudioCodec: "aac",
			EstimatedCPULoad: "high",
		}
	}

	mode := DecidePlayback(probe.VideoCodec, probe.AudioCodec, probe.Container)

	decision := PlaybackDecision{
		Mode:             mode,
		SourceContainer:  probe.Container,
		SourceVideoCodec: probe.VideoCodec,
		SourceAudioCodec: probe.AudioCodec,
	}

	switch mode {
	case DirectPlay:
		decision.Reason = "Container and codecs are fully compatible"
		decision.TargetContainer = probe.Container
		decision.TargetVideoCodec = probe.VideoCodec
		decision.TargetAudioCodec = probe.AudioCodec
		decision.EstimatedCPULoad = "none"

	case RemuxOnly:
		reasons := []string{}
		if !compatibleContainers[probe.Container] {
			reasons = append(reasons, "container "+probe.Container+" needs repackaging")
		}
		if !compatibleAudioCodecs[probe.AudioCodec] {
			reasons = append(reasons, "audio "+probe.AudioCodec+" needs conversion to AAC")
		}
		decision.Reason = joinReasons(reasons)
		decision.TargetContainer = "fmp4/hls"
		decision.TargetVideoCodec = probe.VideoCodec // Copy as-is
		decision.TargetAudioCodec = "aac"
		decision.EstimatedCPULoad = "low"

	case FullTranscode:
		reasons := []string{}
		if !compatibleVideoCodecs[probe.VideoCodec] {
			reasons = append(reasons, "video "+probe.VideoCodec+" needs conversion to H.264")
		}
		if !compatibleContainers[probe.Container] {
			reasons = append(reasons, "container "+probe.Container+" needs repackaging")
		}
		if !compatibleAudioCodecs[probe.AudioCodec] {
			reasons = append(reasons, "audio "+probe.AudioCodec+" needs conversion to AAC")
		}
		decision.Reason = joinReasons(reasons)
		decision.TargetContainer = "fmp4/hls"
		decision.TargetVideoCodec = "h264"
		decision.TargetAudioCodec = "aac"
		decision.EstimatedCPULoad = "high"
	}

	return decision
}

func joinReasons(reasons []string) string {
	if len(reasons) == 0 {
		return "Unknown reason"
	}
	if len(reasons) == 1 {
		return reasons[0]
	}
	// Capitalize first reason, join with "; "
	result := reasons[0]
	for i := 1; i < len(reasons); i++ {
		result += "; " + reasons[i]
	}
	return result
}
