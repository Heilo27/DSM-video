// Package normalize implements TASK-755 auto-normalize: a background, idle-aware,
// low-priority pipeline that converts non-DirectPlay video files into DirectPlay
// form (MP4 + H.264/HEVC + AAC) so the server never has to transcode on playback.
//
// It is the in-process Go port of tools/convert-library.sh — same decision logic,
// same ffmpeg invocations, same data-safety invariant (an original is never
// removed or overwritten until the converted output is ffprobe-verified). The one
// new concern over the script is COEXISTENCE with live playback: a single 4-core /
// 3.8GB software-only NAS must never let a background re-encode starve a viewer's
// transcode. That is enforced by two cooperating mechanisms (see worker.go): the
// worker only runs while the server is idle, and it draws its ffmpeg slot from the
// SAME shared FFmpegLimiter (TASK-752) that live playback uses — via TryAcquire,
// so it yields the instant the box is busy.
package normalize

import (
	"strings"

	"dsvideo/backend/internal/transcode"
)

// Action is what auto-normalize will do with a file. It mirrors the three-tier
// decision in convert-library.sh (skip | remux | encode) and is derived directly
// from transcode.DecidePlayback semantics so there is exactly one source of truth
// for "what counts as DirectPlay" across playback and normalization.
type Action int

const (
	// ActionSkip — the file already DirectPlays (MP4/MOV/M4V + H.264/HEVC + AAC).
	// Nothing to do; leave it untouched.
	ActionSkip Action = iota

	// ActionRemux — video is already H.264/HEVC but the container and/or audio is
	// wrong (e.g. an MKV with AC3/DTS). Copy the video stream untouched and only
	// transcode audio to AAC + repackage to MP4. Cheap, lossless video.
	ActionRemux

	// ActionEncode — video codec is not H.264/HEVC (mpeg4/XVID/VP9/AV1/…), so the
	// video must be fully re-encoded to H.264. Expensive on a CPU-only NAS; this is
	// exactly the work we want to do in the background, once, instead of on every play.
	ActionEncode
)

// String returns a stable lowercase label matching the convert-library.sh verbs,
// used in log lines so the Go pipeline reads the same as the shell one.
func (a Action) String() string {
	switch a {
	case ActionSkip:
		return "skip"
	case ActionRemux:
		return "remux"
	case ActionEncode:
		return "encode"
	default:
		return "unknown"
	}
}

// Decide chooses the normalization Action for a probed file.
//
// It reuses transcode.DecidePlayback (the playback decision engine) rather than
// re-deriving compatibility tables, so a file that the player would DirectPlay is
// always an ActionSkip here, and the Remux/Encode split lines up exactly with
// RemuxOnly/FullTranscode. The mapping:
//
//	DirectPlay   → ActionSkip    (container+video+audio all OK)
//	RemuxOnly    → ActionRemux   (video OK, container/audio wrong)
//	FullTranscode→ ActionEncode  (video codec not H.264/HEVC)
//
// ext is the file extension WITH or WITHOUT a leading dot; it supplies the
// container truth when the probe is nil or the probe's reported container differs
// from the on-disk extension. When probe is non-nil we trust the probe's parsed
// container (it is authoritative — convert-library.sh probed codecs and used the
// extension only for the container check). A nil probe is treated as "unreadable /
// not a video" → ActionSkip, matching the script's `[ -z "$vcodec" ] && skip`.
func Decide(probe *transcode.ProbeResult, ext string) Action {
	if probe == nil || probe.VideoCodec == "" {
		// Unreadable or no video stream — convert-library.sh skips these.
		return ActionSkip
	}

	container := probe.Container
	if container == "" {
		// Fall back to the extension when the probe didn't yield a container name.
		container = strings.TrimPrefix(strings.ToLower(ext), ".")
	}

	switch transcode.DecidePlayback(probe.VideoCodec, probe.AudioCodec, container) {
	case transcode.DirectPlay:
		return ActionSkip
	case transcode.RemuxOnly:
		return ActionRemux
	default: // transcode.FullTranscode
		return ActionEncode
	}
}
