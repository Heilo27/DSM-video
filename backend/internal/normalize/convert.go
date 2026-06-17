package normalize

import (
	"context"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"

	"dsvideo/backend/internal/transcode"
)

// niceLevel is the scheduling nice value applied to every background ffmpeg the
// normalizer launches. 19 is the lowest possible priority — auto-normalize is pure
// background convenience and must always yield CPU to a live playback transcode
// (the HLS path runs at nice 10 by default). This mirrors convert-library.sh's
// intent of "never starve a viewer" and the runFFmpegOnce nice-wrapping in
// transcode/hls.go. (TASK-755)
const niceLevel = 19

// durationTolerance is the fraction by which the converted output's duration may
// differ from the source before we reject it as truncated. ~2% catches a stream
// that ffmpeg cut short (the classic failure mode: a broken-DTS MKV where the
// remux copy stops early) while tolerating the sub-second container-overhead
// differences that are normal between formats. Mirrors convert-library.sh's
// verify step, tightened from "duration > 0" to a proportional check. (TASK-755)
const durationTolerance = 0.02

// Convert produces a DirectPlay MP4 from src according to action, writing to a
// sibling temp file, verifying it with ffprobe, and — only on verify success —
// returning the temp path for the caller to swap into place. It NEVER touches src.
//
// The two ffmpeg recipes are ported verbatim from convert-library.sh:
//
//	Remux : -c:v copy (lossless video) + -c:a aac -b:a 192k -ac 2, repackaged to MP4.
//	Encode: + -c:v libx264 -preset veryfast -crf 21 with a scale cap at maxHeight.
//
// Both use +genpts(+igndts on remux) timestamp repair and +faststart so the moov
// atom is at the front for instant streaming. ffmpeg is wrapped in `nice -n 19`
// exactly like transcode/hls.go runFFmpegOnce, and runs in its own process group
// so a cancelled ctx kills the whole group (the nice wrapper is the direct child;
// ffmpeg is a grandchild that would otherwise orphan).
//
// On ANY failure — non-zero ffmpeg exit, ctx cancellation, or a failed verify —
// the temp file is deleted and an error is returned with src left fully intact.
// This is the data-safety invariant: the caller must only ever remove/replace the
// original after Convert returns a non-empty outPath and nil error. (TASK-755)
func Convert(ctx context.Context, ffmpegPath, ffprobePath, src string, action Action, maxHeight int) (outPath string, err error) {
	if ffmpegPath == "" {
		return "", fmt.Errorf("normalize: ffmpeg path not configured")
	}
	if action == ActionSkip {
		return "", fmt.Errorf("normalize: Convert called with ActionSkip for %s", src)
	}

	dir := filepath.Dir(src)
	base := filepath.Base(src)
	stem := strings.TrimSuffix(base, filepath.Ext(base))
	// Sibling temp ".<stem>.converting.mp4" — same name pattern the scanner skips,
	// so an in-progress conversion never gets indexed as a ghost row (the bug this
	// dotfile name fixes). Final target is "<stem>.mp4" in the same directory.
	tmp := filepath.Join(dir, "."+stem+".converting.mp4")
	finalOut := filepath.Join(dir, stem+".mp4")

	// Clear any stale temp from a previously-killed run before starting fresh.
	_ = os.Remove(tmp)

	args := buildFFmpegArgs(src, tmp, action, maxHeight)

	// nice -n 19 <ffmpeg> <args...> — background priority, identical wrapping to
	// transcode/hls.go so the two ffmpeg paths schedule consistently.
	niceArgs := append([]string{"-n", fmt.Sprintf("%d", niceLevel), ffmpegPath}, args...)
	cmd := exec.CommandContext(ctx, "nice", niceArgs...)
	// Own process group so ctx-cancel kills the nice wrapper AND the ffmpeg
	// grandchild, not just the direct child (same reasoning as hls.go).
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Stdout = nil

	runErr := cmd.Run()
	if runErr != nil {
		_ = os.Remove(tmp)
		if ctx.Err() != nil {
			return "", fmt.Errorf("normalize: ffmpeg %s cancelled for %s: %w", action, src, ctx.Err())
		}
		return "", fmt.Errorf("normalize: ffmpeg %s failed for %s: %w", action, src, runErr)
	}

	// VERIFY before declaring success. A non-zero exit is caught above; this catches
	// the subtler case of ffmpeg exiting 0 but producing a truncated/empty/invalid
	// file. Reject unless the output has a real H.264/HEVC video stream AND its
	// duration is within tolerance of the source. On reject, delete the temp.
	if verr := verifyOutput(ctx, ffprobePath, src, tmp); verr != nil {
		_ = os.Remove(tmp)
		return "", fmt.Errorf("normalize: verify failed for %s: %w", src, verr)
	}

	// Success. Return the verified temp path; the WORKER performs the move+swap
	// (back up original, rename tmp → finalOut) under its tiny IsConverting window.
	// We deliberately do NOT swap here so Convert stays a pure, side-effect-free-on-
	// the-original producer of a verified artifact.
	_ = finalOut // documented target; the worker computes it the same way.
	return tmp, nil
}

// TargetOutputPath returns the final ".mp4" path Convert's output is destined for,
// in the same directory as src. Exposed so the worker computes the swap target
// without duplicating the stem logic.
func TargetOutputPath(src string) string {
	dir := filepath.Dir(src)
	base := filepath.Base(src)
	stem := strings.TrimSuffix(base, filepath.Ext(base))
	return filepath.Join(dir, stem+".mp4")
}

// buildFFmpegArgs assembles the ffmpeg argument list (excluding the binary itself)
// for the given action. Ported directly from convert-library.sh convert_one.
func buildFFmpegArgs(src, tmp string, action Action, maxHeight int) []string {
	if action == ActionRemux {
		// Copy video, transcode audio to AAC, repackage to MP4. +igndts on top of
		// +genpts repairs the broken DTS some MKVs carry. -map 0:a:0? makes audio
		// optional (a video-only file remuxes fine).
		return []string{
			"-nostdin", "-y",
			"-fflags", "+genpts+igndts",
			"-i", src,
			"-map", "0:v:0", "-map", "0:a:0?",
			"-c:v", "copy",
			"-c:a", "aac", "-b:a", "192k", "-ac", "2",
			"-movflags", "+faststart",
			"-avoid_negative_ts", "make_zero",
			tmp,
		}
	}

	// ActionEncode: full re-encode to H.264, capped at maxHeight, never upscaling
	// (scale=-2:min(ih\,H) keeps even width and only downscales). veryfast/crf21 is
	// the proven NAS tradeoff from the script.
	scale := fmt.Sprintf("scale=-2:min(ih\\,%d)", maxHeight)
	return []string{
		"-nostdin", "-y",
		"-fflags", "+genpts",
		"-i", src,
		"-map", "0:v:0", "-map", "0:a:0?",
		"-c:v", "libx264", "-preset", "veryfast", "-crf", "21",
		"-vf", scale,
		"-pix_fmt", "yuv420p",
		"-c:a", "aac", "-b:a", "192k", "-ac", "2",
		"-movflags", "+faststart",
		"-avoid_negative_ts", "make_zero",
		tmp,
	}
}

// verifyOutput re-probes the produced file and confirms it is a sane, playable MP4:
// non-empty, a valid H.264/HEVC video stream, and a duration within durationTolerance
// of the source. Returns nil only when all checks pass. (Port of verify_out.)
func verifyOutput(ctx context.Context, ffprobePath, src, out string) error {
	if info, statErr := os.Stat(out); statErr != nil || info.Size() == 0 {
		return fmt.Errorf("output missing or empty")
	}

	prober := transcode.NewProber(ffprobePath)

	outProbe, err := prober.Probe(ctx, out)
	if err != nil {
		return fmt.Errorf("probe output: %w", err)
	}
	switch outProbe.VideoCodec {
	case "h264", "hevc":
	default:
		return fmt.Errorf("output video codec %q is not H.264/HEVC", outProbe.VideoCodec)
	}
	if outProbe.DurationSecs <= 0 {
		return fmt.Errorf("output duration is zero")
	}

	// Compare against the source duration. If the source is somehow unreadable now,
	// fall back to the "duration > 0" check we already passed rather than rejecting a
	// good output for a transient probe miss on the original.
	srcProbe, srcErr := prober.Probe(ctx, src)
	if srcErr == nil && srcProbe.DurationSecs > 0 {
		diff := math.Abs(outProbe.DurationSecs-srcProbe.DurationSecs) / srcProbe.DurationSecs
		if diff > durationTolerance {
			return fmt.Errorf("output duration %.1fs differs from source %.1fs by %.1f%% (>%.0f%% — truncated)",
				outProbe.DurationSecs, srcProbe.DurationSecs, diff*100, durationTolerance*100)
		}
	}
	return nil
}
