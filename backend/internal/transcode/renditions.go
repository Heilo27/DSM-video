package transcode

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Alternate audio renditions (FR-061).
//
// A source with two or more audio tracks is transcoded in ONE ffmpeg run: the video is
// mapped once and every audio stream after it, and -var_stream_map splits the output into
// one video-only playlist plus one audio-only playlist per track. master.m3u8 then ties
// them together with an EXT-X-MEDIA TYPE=AUDIO group, which is what AVPlayer turns into
// the audible media selection group the player's audio picker lists.
//
// A source with zero or one audio track keeps the original single-playlist output
// (master.m3u8 is itself the media playlist), byte for byte.
//
// Session directory layout for the rendition case:
//
//	master.m3u8                          written by ensureRenditionMaster
//	video.m3u8    init_video.mp4    segment_video_NNNNN.m4s
//	audio_0.m3u8  init_audio_0.mp4  segment_audio_0_NNNNN.m4s
//	audio_1.m3u8  ...

const (
	// audioGroupID ties the EXT-X-MEDIA renditions to the video variant's AUDIO attribute.
	audioGroupID = "aud"
	// videoRendition is the -var_stream_map name of the video-only rendition, so its
	// playlist is video.m3u8.
	videoRendition = "video"
	// defaultRenditionBandwidth stands in for BANDWIDTH when the probe has no bitrate.
	defaultRenditionBandwidth = 8_000_000
)

// audioRendition is the -var_stream_map name of the i-th audio track's rendition, so its
// playlist is audio_<i>.m3u8. The ffmpeg args and the master playlist both name the
// renditions through this one function.
func audioRendition(i int) string { return fmt.Sprintf("audio_%d", i) }

// usesAudioRenditions reports whether the session's output is split into alternate audio
// renditions. Only the single-variant path has a rendition form; the (disabled) ABR
// ladder keeps its own layout.
func usesAudioRenditions(session *HLSSession) bool {
	return !session.UseABR && len(session.AudioTracks) >= 2
}

// hlsCopyableAudio reports whether an audio track can be carried into the fMP4 segments
// as is. Only AAC: MP3-in-fMP4 is a known "resource unavailable" on some players, and
// AC-3/E-AC-3/DTS/TrueHD/FLAC/Opus are not universally decodable by Apple's HLS stack.
func hlsCopyableAudio(codec string) bool { return codec == "aac" }

// audioRenditionArgs returns the -map and per-stream codec arguments for a multi-track
// source: the first video stream once, then every audio track by absolute stream index.
// Each AAC track is copied (no CPU, no generation loss); any other codec is encoded to
// AAC stereo at bitrate, the same settings as the single-track path.
func audioRenditionArgs(tracks []AudioStream, bitrate string) []string {
	args := []string{"-map", "0:v:0"}
	for _, t := range tracks {
		args = append(args, "-map", fmt.Sprintf("0:%d", t.Index))
	}
	for i, t := range tracks {
		if hlsCopyableAudio(t.Codec) {
			args = append(args, fmt.Sprintf("-c:a:%d", i), "copy")
			continue
		}
		args = append(args,
			fmt.Sprintf("-c:a:%d", i), "aac",
			fmt.Sprintf("-b:a:%d", i), bitrate,
			fmt.Sprintf("-ac:a:%d", i), "2",
		)
	}
	return args
}

// varStreamMap builds the -var_stream_map value for n audio tracks: the video alone,
// then each audio stream as its own rendition in the same audio group.
func varStreamMap(n int) string {
	parts := []string{fmt.Sprintf("v:0,agroup:%s,name:%s", audioGroupID, videoRendition)}
	for i := 0; i < n; i++ {
		parts = append(parts, fmt.Sprintf("a:%d,agroup:%s,name:%s", i, audioGroupID, audioRendition(i)))
	}
	return strings.Join(parts, " ")
}

// renditionPlaylists lists every media playlist a rendition session's master references.
func renditionPlaylists(n int) []string {
	names := []string{videoRendition + ".m3u8"}
	for i := 0; i < n; i++ {
		names = append(names, audioRendition(i)+".m3u8")
	}
	return names
}

// buildRenditionMaster renders master.m3u8 for a multi-track session: one EXT-X-MEDIA
// TYPE=AUDIO per source track, in source order, and one video variant that references
// the group.
//
//   - NAME is the track title, else its language tag, else "Track N". HLS requires the
//     names in a group to differ, so a repeat gets a " (2)", " (3)" suffix.
//   - LANGUAGE is the source tag and is omitted when the track is untagged.
//   - Exactly one track is DEFAULT=YES: the first the source marks default, else the
//     first track. Every track is AUTOSELECT=YES so AVPlayer may pick by language.
//   - CHANNELS is what the rendition actually carries: 2 for a track encoded to stereo
//     AAC, the source count for a copied AAC track.
//
// bandwidth is informational: AVPlayer uses BANDWIDTH to choose among variants, and
// there is exactly one.
func buildRenditionMaster(tracks []AudioStream, bandwidth int64) string {
	if bandwidth <= 0 {
		bandwidth = defaultRenditionBandwidth
	}
	def := 0
	for i, t := range tracks {
		if t.Default {
			def = i
			break
		}
	}

	var b strings.Builder
	b.WriteString("#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n")
	used := map[string]bool{}
	for i, t := range tracks {
		name := hlsQuotedSafe(t.Title)
		if name == "" {
			name = hlsQuotedSafe(t.Language)
		}
		if name == "" {
			name = "Track " + strconv.Itoa(i+1)
		}
		unique := name
		for n := 2; used[unique]; n++ {
			unique = fmt.Sprintf("%s (%d)", name, n)
		}
		used[unique] = true

		attrs := []string{"TYPE=AUDIO", fmt.Sprintf(`GROUP-ID="%s"`, audioGroupID)}
		if lang := hlsQuotedSafe(t.Language); lang != "" {
			attrs = append(attrs, fmt.Sprintf(`LANGUAGE="%s"`, lang))
		}
		attrs = append(attrs, fmt.Sprintf(`NAME="%s"`, unique))
		if i == def {
			attrs = append(attrs, "DEFAULT=YES")
		} else {
			attrs = append(attrs, "DEFAULT=NO")
		}
		attrs = append(attrs, "AUTOSELECT=YES")
		channels := 2
		if hlsCopyableAudio(t.Codec) && t.Channels > 0 {
			channels = t.Channels
		}
		attrs = append(attrs,
			fmt.Sprintf(`CHANNELS="%d"`, channels),
			fmt.Sprintf(`URI="%s.m3u8"`, audioRendition(i)),
		)
		b.WriteString("#EXT-X-MEDIA:" + strings.Join(attrs, ",") + "\n")
	}
	fmt.Fprintf(&b, "#EXT-X-STREAM-INF:BANDWIDTH=%d,AUDIO=\"%s\"\n", bandwidth, audioGroupID)
	b.WriteString(videoRendition + ".m3u8\n")
	return b.String()
}

// hlsQuotedSafe makes s legal inside an HLS quoted-string, which may not contain a
// double quote, CR or LF.
func hlsQuotedSafe(s string) string {
	s = strings.NewReplacer(`"`, "'", "\r", " ", "\n", " ").Replace(s)
	return strings.TrimSpace(s)
}

// ensureRenditionMaster writes master.m3u8 for a rendition session once every playlist it
// references exists, and reports whether the master is in place.
//
// It is called from the readiness checks (WaitForPlaylist, IsReady) and at the end of the
// run. The rest of the pipeline treats "master.m3u8 exists" as "playable", so writing it
// before the rendition playlists exist would hand AVPlayer URIs that 404. The write is a
// temp file plus rename, so a reader never sees a partial master.
func (g *HLSGenerator) ensureRenditionMaster(session *HLSSession) (bool, error) {
	session.masterMu.Lock()
	defer session.masterMu.Unlock()

	masterPath := filepath.Join(session.OutputDir, "master.m3u8")
	if nonEmptyFile(masterPath) {
		return true, nil
	}
	for _, name := range renditionPlaylists(len(session.AudioTracks)) {
		if !nonEmptyFile(filepath.Join(session.OutputDir, name)) {
			return false, nil
		}
	}
	content := buildRenditionMaster(session.AudioTracks, session.SourceBitrate)
	if err := writeFileAtomic(masterPath, []byte(content)); err != nil {
		return false, err
	}
	return true, nil
}

// writeFileAtomic writes data to a temp file beside path and renames it into place, so a
// concurrent reader sees the old file or the new one, never a truncated one.
func writeFileAtomic(path string, data []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

// ensureRenditionMasterFor is ensureRenditionMaster by session id, for the readiness
// checks. A no-op for unknown sessions and for single-playlist sessions. AudioTracks,
// UseABR and OutputDir are fixed at session creation, so reading them after releasing
// g.mu is race-free.
func (g *HLSGenerator) ensureRenditionMasterFor(sessionID string) {
	g.mu.Lock()
	session, ok := g.sessions[sessionID]
	g.mu.Unlock()
	if !ok || !usesAudioRenditions(session) {
		return
	}
	if _, err := g.ensureRenditionMaster(session); err != nil {
		log.Printf("[HLS] write rendition master for %s failed: %v", sessionID, err)
	}
}

func nonEmptyFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Size() > 0
}
