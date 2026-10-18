package main

// TASK-1003 / TASK-1004 — the audio tracks a title carries reach the player.
//
// TASK-1003: the web player's realtime remux (handleRemuxStream) ran ffmpeg with no -map,
// which keeps ONE audio stream, so a title with a second language or a commentary track
// lost it on the web plane. A multi-audio title now goes to the HLS audio renditions
// (FR-061) instead, where every track is its own selectable rendition.
//
// TASK-1004: the /playback JSON documents audioTracks as a filled array and returned [].
// It is now filled from the probe, the same source and the same naming the HLS renditions
// use.

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"dsvideo/backend/internal/transcode"
)

type playbackAudioWorld struct {
	s     *Server
	itemI string
}

// ffprobe JSON for a file with one video stream and the given audio streams.
const (
	probeVideoH264 = `{"index":0,"codec_type":"video","codec_name":"h264","codec_tag_string":"avc1","width":1920,"height":1080}`
	probeVideoHEVC = `{"index":0,"codec_type":"video","codec_name":"hevc","codec_tag_string":"hvc1","width":1920,"height":1080}`
	// English AC-3 5.1 titled "Main", the source's default; French AAC stereo, untitled.
	probeAudioEngAC3 = `{"index":1,"codec_type":"audio","codec_name":"ac3","channels":6,"tags":{"language":"eng","title":"Main"},"disposition":{"default":1}}`
	probeAudioFreAAC = `{"index":2,"codec_type":"audio","codec_name":"aac","channels":2,"tags":{"language":"fre"},"disposition":{"default":0}}`
)

// newPlaybackAudioWorld wires a Server with stub ffprobe/ffmpeg binaries (ffprobe prints
// format + streams; ffmpeg exits 1, so a started transcode produces nothing) and one
// cached-codec item at filename inside the movies root.
func newPlaybackAudioWorld(t *testing.T, filename, formatName, vCodec, aCodec, container string, streams ...string) *playbackAudioWorld {
	t.Helper()
	s, db := newProfilesTestServer(t)

	bin := t.TempDir()
	body := `{"format":{"format_name":"` + formatName + `","duration":"60.0"},"streams":[`
	for i, st := range streams {
		if i > 0 {
			body += ","
		}
		body += st
	}
	body += `]}`
	ffprobe := filepath.Join(bin, "ffprobe")
	ffmpeg := filepath.Join(bin, "ffmpeg")
	if err := os.WriteFile(ffprobe, []byte("#!/bin/sh\ncat <<'EOF'\n"+body+"\nEOF\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(ffmpeg, []byte("#!/bin/sh\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	movies := filepath.Join(t.TempDir(), "movies")
	path := filepath.Join(movies, filename)
	writeVideo(t, path)

	s.cfg.MoviesPath = movies
	s.cfg.FFmpegPath = ffmpeg
	s.prober = transcode.NewProber(ffprobe)
	s.ffmpegLimiter = transcode.NewFFmpegLimiter(2)
	// main() builds these maps; the bare test Server does not.
	s.subExtractInFlight = make(map[string]chan struct{})
	s.playSessions = map[string]PlaySession{}
	s.hlsGenerator = transcode.NewHLSGenerator(transcode.HLSConfig{
		FFmpegPath: ffmpeg, TempDir: t.TempDir(), HWAccel: "off",
	})

	const id = "audio-item"
	if _, err := db.Exec(`INSERT INTO items(id, library_id, type, title, path, duration_seconds, added_at, updated_at,
		video_codec, audio_codec, container) VALUES(?, 'lib_movies', 'movie', ?, ?, 60, ?, ?, ?, ?, ?)`,
		id, id, path, "2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z", vCodec, aCodec, container); err != nil {
		t.Fatalf("seed item: %v", err)
	}
	return &playbackAudioWorld{s: s, itemI: id}
}

// playback calls GET /items/{id}/playback and decodes the JSON.
func (w *playbackAudioWorld) playback(t *testing.T, query string) map[string]any {
	t.Helper()
	req := authedRequest(http.MethodGet, "/api/v1/items/"+w.itemI+"/playback"+query, "", "u1", "alice", "")
	req = withURLParam(req, "id", w.itemI)
	rec := httptest.NewRecorder()
	w.s.handlePlayback(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("playback answered %d: %s", rec.Code, rec.Body.String())
	}
	var out map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("undecodable playback JSON %q: %v", rec.Body.String(), err)
	}
	return out
}

func audioTracksOf(t *testing.T, resp map[string]any) []map[string]any {
	t.Helper()
	raw, ok := resp["audioTracks"].([]any)
	if !ok {
		t.Fatalf("audioTracks is %T (%v), want an array", resp["audioTracks"], resp["audioTracks"])
	}
	out := make([]map[string]any, 0, len(raw))
	for _, r := range raw {
		m, ok := r.(map[string]any)
		if !ok {
			t.Fatalf("audioTracks entry is %T, want an object", r)
		}
		out = append(out, m)
	}
	return out
}

// assertTwoTracks checks the documented fields for the stub file's two audio streams.
func assertTwoTracks(t *testing.T, tracks []map[string]any) {
	t.Helper()
	if len(tracks) != 2 {
		t.Fatalf("audioTracks has %d entries, want 2: %v", len(tracks), tracks)
	}
	want := []struct {
		id, label, language, title, codec string
		channels                          float64
		def                               bool
	}{
		{"a1", "Main", "eng", "Main", "ac3", 6, true},
		{"a2", "fre", "fre", "", "aac", 2, false},
	}
	for i, w := range want {
		got := tracks[i]
		if got["id"] != w.id || got["label"] != w.label || got["language"] != w.language ||
			got["title"] != w.title || got["codec"] != w.codec || got["channels"] != w.channels ||
			got["default"] != w.def {
			t.Errorf("audioTracks[%d] = %v, want id=%s label=%s language=%s title=%q codec=%s channels=%v default=%v",
				i, got, w.id, w.label, w.language, w.title, w.codec, w.channels, w.def)
		}
	}
}

// Direct play: the file is served as is, and the JSON still lists its audio tracks.
func TestPlaybackAudioTracks_DirectPlayListsEveryTrack(t *testing.T) {
	w := newPlaybackAudioWorld(t, "film.mp4", "mov,mp4,m4a,3gp,3g2,mj2", "h264", "aac", "mp4",
		probeVideoH264, probeAudioEngAC3, probeAudioFreAAC)
	resp := w.playback(t, "")
	if resp["kind"] != "direct" {
		t.Fatalf("kind = %v, want direct", resp["kind"])
	}
	assertTwoTracks(t, audioTracksOf(t, resp))
}

// HLS: the list is the very one the session turns into renditions, labelled the way the
// master playlist names them.
func TestPlaybackAudioTracks_HLSListsEveryTrack(t *testing.T) {
	w := newPlaybackAudioWorld(t, "film.mkv", "matroska,webm", "hevc", "ac3", "mkv",
		probeVideoHEVC, probeAudioEngAC3, probeAudioFreAAC)
	resp := w.playback(t, "")
	if resp["kind"] != "hls" {
		t.Fatalf("kind = %v, want hls", resp["kind"])
	}
	assertTwoTracks(t, audioTracksOf(t, resp))
}

// A file with no audio stream still answers an array, never null.
func TestPlaybackAudioTracks_NoAudioIsAnEmptyArray(t *testing.T) {
	w := newPlaybackAudioWorld(t, "silent.mp4", "mov,mp4,m4a,3gp,3g2,mj2", "h264", "aac", "mp4", probeVideoH264)
	resp := w.playback(t, "")
	if got := audioTracksOf(t, resp); len(got) != 0 {
		t.Errorf("audioTracks = %v, want []", got)
	}
}

// TASK-1003: a multi-audio MKV (H.264 video, AC-3 audio) used to go to the single-stream
// realtime remux and lose every track after the first. It now goes to HLS renditions.
func TestWebRemux_MultiAudioTitleGoesToHLSRenditions(t *testing.T) {
	w := newPlaybackAudioWorld(t, "film.mkv", "matroska,webm", "h264", "ac3", "mkv",
		probeVideoH264, probeAudioEngAC3, probeAudioFreAAC)
	resp := w.playback(t, "?client=web")
	if resp["kind"] != "hls" {
		t.Fatalf("web multi-audio kind = %v, want hls (the remux keeps one audio track)", resp["kind"])
	}
	if resp["hlsMasterUrl"] == nil || resp["hlsMasterUrl"] == "" {
		t.Errorf("hlsMasterUrl missing: %v", resp)
	}
	assertTwoTracks(t, audioTracksOf(t, resp))
}

// The cheap realtime remux stays the path for a single-audio title.
func TestWebRemux_SingleAudioTitleStaysOnTheRemux(t *testing.T) {
	w := newPlaybackAudioWorld(t, "film.mkv", "matroska,webm", "h264", "ac3", "mkv",
		probeVideoH264, probeAudioEngAC3)
	resp := w.playback(t, "?client=web")
	if resp["kind"] != "direct" || resp["transcoding"] != true {
		t.Fatalf("web single-audio = kind %v transcoding %v, want the remux (direct, transcoding)", resp["kind"], resp["transcoding"])
	}
	if got := audioTracksOf(t, resp); len(got) != 1 || got[0]["label"] != "Main" {
		t.Errorf("audioTracks = %v, want the one track labelled Main", got)
	}
}

// TASK-1028: an MP4 a browser can play as is (H.264 + AAC) was direct played on the web
// plane even with two audio tracks. A browser <video> plays only the file's default track
// and, outside Safari, offers no way to switch, so the French track was unreachable. Such
// a title now goes to the HLS audio renditions too: the video is copied, every track is a
// selectable rendition.
const probeAudioEngAACDefault = `{"index":1,"codec_type":"audio","codec_name":"aac","channels":2,"tags":{"language":"eng","title":"Main"},"disposition":{"default":1}}`

func TestWebDirectPlay_MultiAudioTitleGoesToHLSRenditions(t *testing.T) {
	w := newPlaybackAudioWorld(t, "film.mp4", "mov,mp4,m4a,3gp,3g2,mj2", "h264", "aac", "mp4",
		probeVideoH264, probeAudioEngAACDefault, probeAudioFreAAC)
	resp := w.playback(t, "?client=web")
	if resp["kind"] != "hls" {
		t.Fatalf("web multi-audio MP4 kind = %v, want hls (a browser plays only the default track)", resp["kind"])
	}
	if resp["hlsMasterUrl"] == nil || resp["hlsMasterUrl"] == "" {
		t.Errorf("hlsMasterUrl missing: %v", resp)
	}
	tracks := audioTracksOf(t, resp)
	if len(tracks) != 2 || tracks[0]["label"] != "Main" || tracks[1]["label"] != "fre" || tracks[0]["default"] != true {
		t.Errorf("audioTracks = %v, want Main (default) and fre", tracks)
	}
}

// The same file played by the apps is still direct play: AVPlayer offers every track of
// a direct-played file itself.
func TestWebDirectPlay_MultiAudioTitleIsStillDirectForTheApps(t *testing.T) {
	w := newPlaybackAudioWorld(t, "film.mp4", "mov,mp4,m4a,3gp,3g2,mj2", "h264", "aac", "mp4",
		probeVideoH264, probeAudioEngAACDefault, probeAudioFreAAC)
	resp := w.playback(t, "")
	if resp["kind"] != "direct" || resp["transcoding"] == true {
		t.Fatalf("app multi-audio MP4 = kind %v transcoding %v, want direct play", resp["kind"], resp["transcoding"])
	}
}

// A single-audio browser-playable MP4 stays direct play on the web.
func TestWebDirectPlay_SingleAudioTitleStaysDirect(t *testing.T) {
	w := newPlaybackAudioWorld(t, "film.mp4", "mov,mp4,m4a,3gp,3g2,mj2", "h264", "aac", "mp4",
		probeVideoH264, probeAudioEngAACDefault)
	resp := w.playback(t, "?client=web")
	if resp["kind"] != "direct" || resp["transcoding"] == true {
		t.Fatalf("web single-audio MP4 = kind %v transcoding %v, want direct play", resp["kind"], resp["transcoding"])
	}
}
