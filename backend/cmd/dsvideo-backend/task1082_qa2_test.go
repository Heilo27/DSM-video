package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"dsvideo/backend/internal/transcode"
)

// Second, blind QA pass of TASK-1082 (Worf), written against fix commit 6143f88: D1 (the ".."
// containment bypass; resolveMediaPath returns the CHECKED path every caller must open) and
// D2 (per-SID singleflight in sid_validation.go).
//
// Expected values are literals built from the fixture directories only; no production
// symbol is used to compute an expectation. Persisted rows are read back through the
// handlers, not through the structure that was written.

// ---------------------------------------------------------------------------------------
// D1: resolveMediaPath
// ---------------------------------------------------------------------------------------

// d1Fixture lays out:
//
//	base/Movies/Heat.mkv            (the root)
//	base/Movies/real/a.mkv
//	base/Movies/alias   -> base/Movies/real      (link staying inside)
//	base/Movies/outlink -> base/private/sub      (link leaving the root)
//	base/Movies/dead    -> base/nowhere          (dangling)
//	base/Movies2/other.mkv                       (string-prefix sibling of the root)
//	base/private/secret.txt, base/private/sub/
type d1Fixture struct {
	base, root, sibling, outside string
}

func newD1Fixture(t *testing.T) d1Fixture {
	t.Helper()
	base := realTemp(t)
	f := d1Fixture{base: base, root: base + "/Movies", sibling: base + "/Movies2", outside: base + "/private"}
	mkdirs(t, f.root, f.sibling, f.outside+"/sub")
	writeFile(t, f.root+"/Heat.mkv", "x")
	writeFile(t, f.root+"/real/a.mkv", "x")
	writeFile(t, f.sibling+"/other.mkv", "x")
	writeFile(t, f.outside+"/secret.txt", "TOPSECRET")
	for target, name := range map[string]string{
		f.root + "/real":          "alias",
		f.outside + "/sub":        "outlink",
		f.base + "/nowhere":       "dead",
		f.root + "/NoSuchDir":     "danglingdir",
		f.outside + "/secret.txt": "leak.mkv",
	} {
		if err := os.Symlink(target, f.root+"/"+name); err != nil {
			t.Fatal(err)
		}
	}
	return f
}

// Red if: resolveMediaPath (a) approves a path whose ".." the OS applies AFTER following a
// link out of the root, (b) refuses a ".." path that really stays inside the root, (c)
// returns anything other than the symlink-resolved, ".."-free path, or (d) lets a prefix
// sibling, the empty string or a dangling link through.
func TestQA1082B_ResolveMediaPathMatrix(t *testing.T) {
	f := newD1Fixture(t)
	s := serverWithRoots(f.root, "", "")

	cases := []struct {
		name     string
		path     string
		wantOK   bool
		wantPath string // only checked when wantOK
	}{
		// ".." in fully existing paths
		{"dotdot folds inside a plain dir", f.root + "/real/../Heat.mkv", true, f.root + "/Heat.mkv"},
		{"dotdot after an inside link lands back inside", f.root + "/alias/../Heat.mkv", true, f.root + "/Heat.mkv"},
		{"dotdot after an OUTSIDE link leaves the root", f.root + "/outlink/../secret.txt", false, ""},
		{"dotdot after an outside link and back into the root", f.root + "/outlink/../../Movies/Heat.mkv", true, f.root + "/Heat.mkv"},
		{"dotdot out of the root to a prefix sibling", f.root + "/../Movies2/other.mkv", false, ""},
		{"dotdot out of the root and straight back in", f.root + "/../Movies/Heat.mkv", true, f.root + "/Heat.mkv"},
		{"dotdot climbing past the filesystem root", f.root + "/../../../../../../../../etc/hosts", false, ""},
		// ".." in partially missing / dangling paths: cannot be resolved safely, fail closed
		{"dotdot with a missing directory before it", f.root + "/nope/../Heat.mkv", false, ""},
		{"dotdot after an existing dir then a missing tail", f.root + "/real/../nope/x.srt", false, ""},
		{"dotdot after a dangling link", f.root + "/dead/../Heat.mkv", false, ""},
		{"dotdot after a missing dir that would escape", f.root + "/nope/../../private/secret.txt", false, ""},
		// cosmetic path shapes
		{"dot component", f.root + "/./Heat.mkv", true, f.root + "/Heat.mkv"},
		{"double slash", f.root + "//Heat.mkv", true, f.root + "/Heat.mkv"},
		{"root with trailing slash", f.root + "/", true, f.root},
		{"root itself", f.root, true, f.root},
		{"root with dot", f.root + "/.", true, f.root},
		{"trailing slash after a real dir", f.root + "/real/", true, f.root + "/real"},
		{"missing sidecar", f.root + "/Heat.en.srt", true, f.root + "/Heat.en.srt"},
		{"missing sidecar under an inside link", f.root + "/alias/new.srt", true, f.root + "/real/new.srt"},
		{"missing sidecar in missing dirs", f.root + "/a/b/c.srt", true, f.root + "/a/b/c.srt"},
		// not under the root
		{"prefix sibling", f.sibling + "/other.mkv", false, ""},
		{"prefix sibling by raw string extension", f.root + "2/other.mkv", false, ""},
		{"outside directly", f.outside + "/secret.txt", false, ""},
		{"file link out", f.root + "/leak.mkv", false, ""},
		{"dangling link itself", f.root + "/dead", false, ""},
		{"missing file under a dangling dir link", f.root + "/danglingdir/x.srt", false, ""},
		{"empty", "", false, ""},
		{"relative", "Heat.mkv", false, ""},
	}
	for _, c := range cases {
		got, ok := s.resolveMediaPath(c.path)
		if ok != c.wantOK {
			t.Errorf("%s: resolveMediaPath(%q) ok = %v, want %v (resolved %q)", c.name, c.path, ok, c.wantOK, got)
			continue
		}
		if !ok {
			if got != "" {
				t.Errorf("%s: refused path must return the empty string, got %q", c.name, got)
			}
			continue
		}
		if got != c.wantPath {
			t.Errorf("%s: resolveMediaPath(%q) = %q, want %q", c.name, c.path, got, c.wantPath)
		}
		for _, el := range strings.Split(got, "/") {
			if el == ".." || el == "." {
				t.Errorf("%s: returned path %q still has a %q element", c.name, got, el)
			}
		}
		if strings.Contains(got, "//") {
			t.Errorf("%s: returned path %q has a doubled separator", c.name, got)
		}
		// OS oracle: where the file exists, the returned path IS the file the raw string opens.
		if rawInfo, err := os.Stat(c.path); err == nil {
			gotInfo, gerr := os.Stat(got)
			if gerr != nil || !os.SameFile(rawInfo, gotInfo) {
				t.Errorf("%s: the OS opens %q and %q as different files (stat err %v)", c.name, c.path, got, gerr)
			}
		}
	}
}

// Red if: the root-itself-is-a-symlink case (a NAS volume mounted through a link) stops
// working with a ".." in the path, or the ".." is resolved against the link instead of its
// target.
func TestQA1082B_ResolveMediaPathThroughASymlinkedRoot(t *testing.T) {
	f := newD1Fixture(t)
	linkRoot := f.base + "/MoviesLink"
	if err := os.Symlink(f.root, linkRoot); err != nil {
		t.Fatal(err)
	}
	s := serverWithRoots(linkRoot, "", "")

	got, ok := s.resolveMediaPath(linkRoot + "/real/../Heat.mkv")
	if !ok || got != f.root+"/Heat.mkv" {
		t.Fatalf("symlinked root + inside dotdot = (%q, %v), want (%q, true)", got, ok, f.root+"/Heat.mkv")
	}
	if got, ok := s.resolveMediaPath(linkRoot + "/outlink/../secret.txt"); ok {
		t.Fatalf("symlinked root + outside link + dotdot approved as %q", got)
	}
	if got, ok := s.resolveMediaPath(linkRoot); !ok || got != f.root {
		t.Fatalf("the symlinked root itself = (%q, %v), want (%q, true)", got, ok, f.root)
	}
}

// Red if: the containment check compares a normalised string while the OS compares bytes
// (or the other way round) so the returned path stops naming the file the raw string opens.
// macOS APFS treats NFC and NFD as one name; a Synology volume does not. Both are valid, so
// the assertion is against the OS (SameFile), never against an assumed answer.
func TestQA1082B_ResolveMediaPathUnicodeNFCvsNFD(t *testing.T) {
	f := newD1Fixture(t)
	nfc := "Caf\u00e9 (2020).mkv"
	nfd := "Cafe\u0301 (2020).mkv"
	writeFile(t, f.root+"/"+nfc, "x")
	s := serverWithRoots(f.root, "", "")

	got, ok := s.resolveMediaPath(f.root + "/" + nfd)
	if !ok {
		t.Fatalf("an NFD spelling of a name under the root was refused (resolved %q)", got)
	}
	if !strings.HasPrefix(got, f.root+"/") {
		t.Fatalf("NFD path resolved outside the root: %q", got)
	}
	rawInfo, rawErr := os.Stat(f.root + "/" + nfd)
	if rawErr == nil { // normalisation-insensitive filesystem: it is the same file
		gotInfo, err := os.Stat(got)
		if err != nil || !os.SameFile(rawInfo, gotInfo) {
			t.Fatalf("returned %q is not the file the NFD string opens (stat err %v)", got, err)
		}
	}
	// A ".." after a Unicode directory name must still be applied by the OS, not lexically.
	uni := f.root + "/\u00fcber"
	mkdirs(t, uni)
	if err := os.Symlink(f.outside+"/sub", uni+"/out"); err != nil {
		t.Fatal(err)
	}
	if got, ok := s.resolveMediaPath(uni + "/out/../secret.txt"); ok {
		t.Fatalf("unicode dir + outside link + dotdot approved as %q", got)
	}
}

// ---------------------------------------------------------------------------------------
// D1: every caller opens the CHECKED path
// ---------------------------------------------------------------------------------------

// d1World is a playback world (stub ffprobe/ffmpeg, one mp4 item) plus:
//
//	<movies>/sub/                      (an inside directory)
//	<movies>/alias -> <movies>/sub     (inside link)
//	<movies>/link  -> <outside>/sub    (link leaving the root)
//	<outside>/secret.mp4               (a real file outside the library)
type d1World struct {
	*playbackAudioWorld
	movies, outside string // movies is symlink-resolved
	ffmpegLog       string
}

func newD1World(t *testing.T) d1World {
	t.Helper()
	w := newPlaybackAudioWorld(t, "film.mp4", "mov,mp4,m4a,3gp,3g2,mj2", "h264", "aac", "mp4", probeVideoH264, probeAudioFreAAC)
	movies, err := filepath.EvalSymlinks(w.s.cfg.MoviesPath) // macOS t.TempDir() sits behind /var -> /private/var
	if err != nil {
		t.Fatal(err)
	}
	outside := realTemp(t)
	mkdirs(t, movies+"/sub", outside+"/sub")
	writeFile(t, outside+"/secret.mp4", "SECRET")
	if err := os.Symlink(movies+"/sub", movies+"/alias"); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside+"/sub", movies+"/link"); err != nil {
		t.Fatal(err)
	}
	// Replace the stub ffmpeg with one that records every argument it is handed.
	logFile := filepath.Join(t.TempDir(), "ffmpeg.args")
	script := "#!/bin/sh\necho \"$@\" >> '" + logFile + "'\nexit 1\n"
	if err := os.WriteFile(w.s.cfg.FFmpegPath, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return d1World{playbackAudioWorld: w, movies: movies, outside: outside, ffmpegLog: logFile}
}

func (w d1World) setItemPath(t *testing.T, p string) {
	t.Helper()
	if _, err := w.s.db.Exec(`UPDATE items SET path = ? WHERE id = ?`, p, w.itemI); err != nil {
		t.Fatal(err)
	}
}

func (w d1World) sessionPaths() []string {
	w.s.mu.Lock()
	defer w.s.mu.Unlock()
	var out []string
	for _, ps := range w.s.playSessions {
		out = append(out, ps.Path)
	}
	return out
}

func (w d1World) rawPlayback(query string) *httptest.ResponseRecorder {
	req := authedRequest(http.MethodGet, "/api/v1/items/"+w.itemI+"/playback"+query, "", "u1", "alice", "")
	req = withURLParam(req, "id", w.itemI)
	rec := httptest.NewRecorder()
	w.s.handlePlayback(rec, req)
	return rec
}

// Red if: handlePlayback checks a resolved path but opens/stat/probes/sessions the raw DB
// string (the original D1), or refuses a plain file after the change.
func TestQA1082B_HandlePlaybackOpensTheCheckedPath(t *testing.T) {
	w := newD1World(t)

	// Tampered row: root/link/../secret.mp4 is root/secret.mp4 lexically, <outside>/secret.mp4 to the OS.
	raw := w.movies + "/link/../secret.mp4"
	if b, err := os.ReadFile(raw); err != nil || string(b) != "SECRET" {
		t.Fatalf("precondition: the OS must open the outside file through %q, got %q, %v", raw, b, err)
	}
	w.setItemPath(t, raw)
	rec := w.rawPlayback("")
	if rec.Code != http.StatusForbidden || !strings.Contains(rec.Body.String(), "path_not_allowed") {
		t.Fatalf("tampered row answered %d %s, want 403 path_not_allowed", rec.Code, rec.Body.String())
	}
	if n := len(w.sessionPaths()); n != 0 {
		t.Fatalf("a refused playback created %d play session(s)", n)
	}

	// ".." through an INSIDE link: legitimately inside, and the session must carry the
	// resolved path (no ".."), not the raw string.
	w.setItemPath(t, w.movies+"/alias/../film.mp4")
	rec = w.rawPlayback("")
	if rec.Code != http.StatusOK {
		t.Fatalf("inside-link dotdot path refused: %d %s", rec.Code, rec.Body.String())
	}
	if got := w.sessionPaths(); len(got) != 1 || got[0] != w.movies+"/film.mp4" {
		t.Fatalf("session paths = %q, want exactly [%q]", got, w.movies+"/film.mp4")
	}
}

// Red if: a plain, non-symlink file stops playing through handlePlayback (the common case),
// or the session stops pointing at that file.
func TestQA1082B_HandlePlaybackPlainFileStillPlays(t *testing.T) {
	w := newD1World(t)
	resp := w.playback(t, "")
	if resp["kind"] != "direct" {
		t.Fatalf("kind = %v, want direct", resp["kind"])
	}
	if got := w.sessionPaths(); len(got) != 1 || got[0] != w.movies+"/film.mp4" {
		t.Fatalf("session paths = %q, want exactly [%q]", got, w.movies+"/film.mp4")
	}
	// A path equal to the media root itself is a directory, not a title: stat succeeds but
	// it must not become a session the streaming handler would serve.
	w.setItemPath(t, w.movies+"/../"+filepath.Base(w.movies)+"2/none.mp4")
	rec := w.rawPlayback("")
	if rec.Code != http.StatusForbidden {
		t.Fatalf("a root-prefix sibling path answered %d, want 403", rec.Code)
	}
}

// Red if: the trickplay handler skips the guard, or hands ffmpeg the raw ".." string rather
// than the checked path.
func TestQA1082B_TrickplayRefusesDotDotEscapeAndFeedsFFmpegTheCheckedPath(t *testing.T) {
	w := newD1World(t)
	w.s.trickplayInFlight = make(map[string]chan struct{}) // set by the real constructor, not by the test world
	vtt := func() *httptest.ResponseRecorder {
		req := authedRequest(http.MethodGet, "/api/v1/trickplay/"+w.itemI+"/trickplay.vtt", "", "u1", "alice", "")
		req = withURLParam(req, "itemId", w.itemI)
		rec := httptest.NewRecorder()
		w.s.handleTrickplayVTT(rec, req)
		return rec
	}

	w.setItemPath(t, w.movies+"/link/../secret.mp4")
	rec := vtt()
	if rec.Code != http.StatusForbidden || !strings.Contains(rec.Body.String(), "path_not_allowed") {
		t.Fatalf("tampered trickplay row answered %d %s, want 403 path_not_allowed", rec.Code, rec.Body.String())
	}
	if _, err := os.Stat(w.ffmpegLog); err == nil {
		b, _ := os.ReadFile(w.ffmpegLog)
		t.Fatalf("ffmpeg was run for a refused path: %s", b)
	}

	w.setItemPath(t, w.movies+"/alias/../film.mp4")
	rec = vtt()
	if rec.Code != http.StatusNotFound || !strings.Contains(rec.Body.String(), "trickplay_unavailable") {
		t.Fatalf("allowed path answered %d %s, want 404 trickplay_unavailable (guard passed, stub ffmpeg fails)", rec.Code, rec.Body.String())
	}
	args, err := os.ReadFile(w.ffmpegLog)
	if err != nil {
		t.Fatalf("ffmpeg never ran for the allowed path: %v", err)
	}
	if !strings.Contains(string(args), "-i "+w.movies+"/film.mp4 ") {
		t.Fatalf("ffmpeg was not handed the checked path; args: %s", args)
	}
	if strings.Contains(string(args), "..") {
		t.Fatalf("ffmpeg received a raw \"..\" path: %s", args)
	}
}

func insertPlayRow(t *testing.T, s *Server, id, path, kind string) {
	t.Helper()
	now := time.Now().UTC().Format(time.RFC3339)
	if _, err := s.db.Exec(`INSERT INTO play_sessions(session_id, item_id, path, kind, playback_mode, transcoding, user_id, profile_id, created_at, last_access)
		VALUES(?, 'audio-item', ?, ?, 0, 0, 'u1', NULL, ?, ?)`, id, path, kind, now, now); err != nil {
		t.Fatal(err)
	}
}

// Red if: rehydratePlaySession resumes a persisted session whose path escapes via "..", or
// resumes the raw string instead of the resolved one, or no longer resumes a plain file.
func TestQA1082B_RehydrateChecksAndReturnsTheResolvedPath(t *testing.T) {
	w := newD1World(t)
	insertPlayRow(t, w.s, "vs_escape", w.movies+"/link/../secret.mp4", "direct")
	insertPlayRow(t, w.s, "vs_inside", w.movies+"/alias/../film.mp4", "direct")
	insertPlayRow(t, w.s, "vs_plain", w.movies+"/film.mp4", "direct")

	if ps, ok := w.s.rehydratePlaySession("vs_escape"); ok {
		t.Fatalf("rehydrated a session escaping the root via dotdot: %+v", ps)
	}
	if _, cached := w.s.playSessions["vs_escape"]; cached {
		t.Fatal("a refused rehydrate still cached the session")
	}
	ps, ok := w.s.rehydratePlaySession("vs_inside")
	if !ok || ps.Path != w.movies+"/film.mp4" {
		t.Fatalf("inside dotdot rehydrate = (%q, %v), want (%q, true)", ps.Path, ok, w.movies+"/film.mp4")
	}
	ps, ok = w.s.rehydratePlaySession("vs_plain")
	if !ok || ps.Path != w.movies+"/film.mp4" {
		t.Fatalf("plain rehydrate = (%q, %v), want (%q, true)", ps.Path, ok, w.movies+"/film.mp4")
	}
}

// Red if: the Synology WebAPI "open" skips the guard or stores the raw DB string as the path
// http.ServeFile later serves (vtestreaming serves ps.Path verbatim).
func TestQA1082B_WebAPIStreamingOpenStoresTheCheckedPath(t *testing.T) {
	w := newD1World(t)
	const sid = "qa-1082b-stream-sid"
	session := &WebAPISession{SID: sid, UserID: "u1", Username: "alice"}
	m := getOrCreateMapping(sid)
	m.mu.Lock()
	m.movieIDs["7"] = w.itemI
	m.mu.Unlock()
	t.Cleanup(func() { idMappingsMu.Lock(); delete(idMappings, sid); idMappingsMu.Unlock() })

	open := func() (map[string]any, *httptest.ResponseRecorder) {
		req := httptest.NewRequest(http.MethodGet, `/webapi/entry.cgi?file={"id":7}`, nil)
		rec := httptest.NewRecorder()
		w.s.webAPIStreamingOpen(rec, req, session)
		var out map[string]any
		_ = json.Unmarshal(rec.Body.Bytes(), &out)
		return out, rec
	}

	w.setItemPath(t, w.movies+"/link/../secret.mp4")
	out, rec := open()
	errObj, _ := out["error"].(map[string]any)
	if out["success"] != false || errObj["code"] != float64(1101) {
		t.Fatalf("tampered row: got %s, want success=false error.code=1101", rec.Body.String())
	}
	if n := len(w.sessionPaths()); n != 0 {
		t.Fatalf("a refused open created %d session(s)", n)
	}

	w.setItemPath(t, w.movies+"/alias/../film.mp4")
	out, rec = open()
	data, _ := out["data"].(map[string]any)
	if out["success"] != true || data["stream_id"] == nil {
		t.Fatalf("inside dotdot open refused: %s", rec.Body.String())
	}
	if got := w.sessionPaths(); len(got) != 1 || got[0] != w.movies+"/film.mp4" {
		t.Fatalf("stored session paths = %q, want exactly [%q]", got, w.movies+"/film.mp4")
	}
}

// Red if: collectEmbeddedSubtitles / ensureEmbeddedSubs lets a ".." escape reach ffmpeg or the
// ingest queue, or queues the raw path instead of the resolved one, or refuses a plain file.
func TestQA1082B_EmbeddedSubsRefuseDotDotAndQueueTheResolvedPath(t *testing.T) {
	w := newD1World(t)
	s := w.s
	s.cfg.TranscodeDir = t.TempDir()
	// A queue with no worker: queued jobs stay observable and ffmpeg is never run.
	s.subIngestOnce.Do(func() { s.subIngestQ = make(chan subIngestJob, 8) })
	probe := &transcode.ProbeResult{}

	var buf syncBuffer
	prev := log.Writer()
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(prev) })

	if tracks := s.collectEmbeddedSubtitles("item-esc", w.movies+"/link/../secret.mp4", 0, probe); tracks != nil {
		t.Fatalf("escape returned tracks: %v", tracks)
	}
	s.ensureEmbeddedSubs("item-esc2", w.movies+"/link/../secret.mp4", probe)
	if n := len(s.subIngestQ); n != 0 {
		t.Fatalf("a refused path queued %d ingest job(s)", n)
	}
	if got := strings.Count(buf.String(), "not within any media root"); got != 2 {
		t.Fatalf("expected 2 media-root refusals in the log, got %d:\n%s", got, buf.String())
	}

	s.ensureEmbeddedSubs("item-ok", w.movies+"/alias/../film.mp4", probe)
	select {
	case job := <-s.subIngestQ:
		if job.videoPath != w.movies+"/film.mp4" || job.itemID != "item-ok" {
			t.Fatalf("queued job = %q for %q, want path %q for item-ok", job.videoPath, job.itemID, w.movies+"/film.mp4")
		}
	default:
		t.Fatal("an allowed path queued no ingest job")
	}
}

// ---------------------------------------------------------------------------------------
// D2: the SID singleflight
// ---------------------------------------------------------------------------------------

// spyCtx counts how many times Done() is read. In validateUnknownSID the only reader is
// awaitFlight, so the count is the number of followers that are parked on a flight.
type spyCtx struct {
	context.Context
	waiting *atomic.Int32
}

func (c spyCtx) Done() <-chan struct{} {
	c.waiting.Add(1)
	return c.Context.Done()
}

func spyRequest(sid, ip string, ctx context.Context, waiting *atomic.Int32) *http.Request {
	return sidRequest(sid, ip, "qa").WithContext(spyCtx{Context: ctx, waiting: waiting})
}

type sidResult struct {
	account string
	err     error
}

func flightCount(g *sidValidationGuard) int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return len(g.flight)
}

// startFollowers runs n requests for sid that must all park on the flight.
func startFollowers(t *testing.T, s *Server, sid, ip string, n int, ctx context.Context) (<-chan sidResult, *atomic.Int32) {
	t.Helper()
	var waiting atomic.Int32
	out := make(chan sidResult, n)
	for i := 0; i < n; i++ {
		go func() {
			acc, err := s.validateUnknownSID(spyRequest(sid, ip, ctx, &waiting), sid)
			out <- sidResult{acc, err}
		}()
	}
	waitFor(t, fmt.Sprintf("%d followers to park", n), func() bool { return int(waiting.Load()) == n })
	return out, &waiting
}

// Red if: a panic inside the DSM call leaves the flight registered, strands followers on a
// channel nobody closes, leaks the concurrency slot, or hands followers an account.
func TestQA1082B_LeaderPanicReleasesFollowersFailedClosedAndCleansUp(t *testing.T) {
	entered := make(chan struct{})
	release := make(chan struct{})
	var calls atomic.Int32
	s := sidServer(t, func(string) (string, error) {
		if calls.Add(1) == 1 {
			close(entered)
			<-release
			panic("dsm client blew up")
		}
		return "ryan", nil
	})
	g := s.sidGuardFor()
	const sid, ip = "qa-sid-panic-0001", "10.40.0.1"

	leaderDone := make(chan any, 1)
	go func() {
		defer func() { leaderDone <- recover() }()
		_, _ = s.validateUnknownSID(sidRequest(sid, ip, "qa"), sid)
	}()
	<-entered
	results, _ := startFollowers(t, s, sid, ip, 10, context.Background())
	close(release)

	if r := <-leaderDone; r != "dsm client blew up" {
		t.Fatalf("leader recovered %v, want the original panic to propagate", r)
	}
	for i := 0; i < 10; i++ {
		select {
		case res := <-results:
			if res.account != "" || res.err == nil {
				t.Fatalf("follower %d got (%q, %v) after a leader panic, want (\"\", error)", i, res.account, res.err)
			}
		case <-time.After(3 * time.Second):
			t.Fatalf("follower %d is still blocked 3s after the leader panicked", i)
		}
	}
	if n := flightCount(g); n != 0 {
		t.Fatalf("flight map holds %d entries after the leader panicked", n)
	}
	if n := len(g.sem); n != 0 {
		t.Fatalf("concurrency slot leaked: %d held after the leader panicked", n)
	}
	// Not poisoned: the very next request does a fresh validation and succeeds.
	acc, err := s.validateUnknownSID(sidRequest(sid, ip, "qa"), sid)
	if acc != "ryan" || err != nil || calls.Load() != 2 {
		t.Fatalf("after the panic: (%q, %v) with %d DSM calls, want (\"ryan\", nil) with 2", acc, err, calls.Load())
	}
}

// Red if: a follower whose own request is cancelled stays parked until the leader finishes
// (or is released by the wrong channel), takes the leader down with it, or gets an account.
func TestQA1082B_FollowerCancelReturnsPromptlyAndLeaderIsUnaffected(t *testing.T) {
	entered := make(chan struct{})
	release := make(chan struct{})
	s := sidServer(t, func(string) (string, error) {
		close(entered)
		<-release
		return "ryan", nil
	})
	g := s.sidGuardFor()
	const sid, ip = "qa-sid-cancel-0001", "10.40.0.2"

	leader := make(chan sidResult, 1)
	go func() {
		a, e := s.validateUnknownSID(sidRequest(sid, ip, "qa"), sid)
		leader <- sidResult{a, e}
	}()
	<-entered

	cancelCtx, cancel := context.WithCancel(context.Background())
	cancelled, _ := startFollowers(t, s, sid, ip, 1, cancelCtx)
	patient, _ := startFollowers(t, s, sid, ip, 3, context.Background())
	cancel()

	select {
	case res := <-cancelled:
		if res.account != "" || !errors.Is(res.err, context.Canceled) {
			t.Fatalf("cancelled follower = (%q, %v), want (\"\", context.Canceled)", res.account, res.err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("a cancelled follower is still parked while the leader runs")
	}
	if n := flightCount(g); n != 1 {
		t.Fatalf("flight map has %d entries while the leader is still running, want 1", n)
	}
	close(release)
	if res := <-leader; res.account != "ryan" || res.err != nil {
		t.Fatalf("leader = (%q, %v) after a follower cancelled, want (\"ryan\", nil)", res.account, res.err)
	}
	for i := 0; i < 3; i++ {
		if res := <-patient; res.account != "ryan" || res.err != nil {
			t.Fatalf("patient follower %d = (%q, %v), want (\"ryan\", nil)", i, res.account, res.err)
		}
	}
	if n := flightCount(g); n != 0 {
		t.Fatalf("flight map holds %d entries after completion", n)
	}
}

// Red if: the leader's own request being cancelled aborts the shared validation, so the
// followers (whose requests are alive) are told "invalid" or get nothing.
func TestQA1082B_LeaderCancelDoesNotFailTheFollowers(t *testing.T) {
	entered := make(chan struct{})
	release := make(chan struct{})
	s := sidServer(t, func(string) (string, error) {
		close(entered)
		<-release
		return "ryan", nil
	})
	const sid, ip = "qa-sid-lcancel-001", "10.40.0.3"

	ctx, cancel := context.WithCancel(context.Background())
	leader := make(chan sidResult, 1)
	go func() {
		a, e := s.validateUnknownSID(sidRequest(sid, ip, "qa").WithContext(ctx), sid)
		leader <- sidResult{a, e}
	}()
	<-entered
	followers, _ := startFollowers(t, s, sid, ip, 5, context.Background())
	cancel()
	close(release)
	for i := 0; i < 5; i++ {
		if res := <-followers; res.account != "ryan" || res.err != nil {
			t.Fatalf("follower %d = (%q, %v) after the leader's request was cancelled, want (\"ryan\", nil)", i, res.account, res.err)
		}
	}
	<-leader
}

// Red if: a transport error is negative-cached or sticks to the SID (the next request must
// retry DSM), the burst waiting on the failed call is given an account, or the flight
// outlives its result.
func TestQA1082B_ErrorIsSharedWithTheBurstThenForgotten(t *testing.T) {
	entered := make(chan struct{})
	release := make(chan struct{})
	var calls atomic.Int32
	s := sidServer(t, func(string) (string, error) {
		if calls.Add(1) == 1 {
			close(entered)
			<-release
			return "", errors.New("dial tcp: i/o timeout")
		}
		return "ryan", nil
	})
	g := s.sidGuardFor()
	const sid, ip = "qa-sid-err-000001", "10.40.0.4"

	leader := make(chan sidResult, 1)
	go func() {
		a, e := s.validateUnknownSID(sidRequest(sid, ip, "qa"), sid)
		leader <- sidResult{a, e}
	}()
	<-entered
	followers, _ := startFollowers(t, s, sid, ip, 6, context.Background())
	close(release)

	check := func(who string, res sidResult) {
		if res.account != "" || res.err == nil || errors.Is(res.err, errDSMSessionInvalid) {
			t.Errorf("%s = (%q, %v), want (\"\", transport error that is NOT errDSMSessionInvalid)", who, res.account, res.err)
		}
	}
	check("leader", <-leader)
	for i := 0; i < 6; i++ {
		check(fmt.Sprintf("follower %d", i), <-followers)
	}
	if n := flightCount(g); n != 0 {
		t.Fatalf("flight map holds %d entries after an error result", n)
	}
	g.mu.Lock()
	negs := len(g.negative)
	g.mu.Unlock()
	if negs != 0 {
		t.Fatalf("a transport error was negative-cached (%d entries)", negs)
	}
	acc, err := s.validateUnknownSID(sidRequest(sid, ip, "qa"), sid)
	if acc != "ryan" || err != nil || calls.Load() != 2 {
		t.Fatalf("retry after the shared error = (%q, %v) with %d DSM calls, want (\"ryan\", nil) with 2", acc, err, calls.Load())
	}
}

// Red if: a definitive "invalid" from a coalesced burst is not cached afterwards (every
// replay would cost a DSM call again), is given to followers as an account, or is cached
// per follower instead of once.
func TestQA1082B_DefinitiveInvalidFromABurstIsCachedOnce(t *testing.T) {
	entered := make(chan struct{})
	release := make(chan struct{})
	var calls atomic.Int32
	s := sidServer(t, func(string) (string, error) {
		calls.Add(1)
		close(entered)
		<-release
		return "", errDSMSessionInvalid
	})
	g := s.sidGuardFor()
	const sid, ip = "qa-sid-inval-0001", "10.40.0.5"

	leader := make(chan sidResult, 1)
	go func() {
		a, e := s.validateUnknownSID(sidRequest(sid, ip, "qa"), sid)
		leader <- sidResult{a, e}
	}()
	<-entered
	followers, _ := startFollowers(t, s, sid, ip, 5, context.Background())
	close(release)
	if res := <-leader; res.account != "" || !errors.Is(res.err, errDSMSessionInvalid) {
		t.Fatalf("leader = (%q, %v), want (\"\", errDSMSessionInvalid)", res.account, res.err)
	}
	for i := 0; i < 5; i++ {
		if res := <-followers; res.account != "" || !errors.Is(res.err, errDSMSessionInvalid) {
			t.Fatalf("follower %d = (%q, %v), want (\"\", errDSMSessionInvalid)", i, res.account, res.err)
		}
	}
	for i := 0; i < 20; i++ { // replays: all answered from the negative cache
		if _, err := s.validateUnknownSID(sidRequest(sid, ip, "qa"), sid); !errors.Is(err, errDSMSessionInvalid) {
			t.Fatalf("replay %d err = %v, want errDSMSessionInvalid", i, err)
		}
	}
	if calls.Load() != 1 {
		t.Fatalf("DSM was called %d times for one invalid SID, want 1", calls.Load())
	}
	g.mu.Lock()
	negs := len(g.negative)
	g.mu.Unlock()
	if negs != 1 || flightCount(g) != 0 {
		t.Fatalf("negative cache entries = %d (want 1), flights = %d (want 0)", negs, flightCount(g))
	}
}

// Red if: coalescing weakens the bound on DISTINCT SIDs: 100 different unknown SIDs from one
// address must reach DSM at most sidValidationInflight (8) at a time, and no more than the
// per-address budget (30) per window in total; the rest fail closed with the right reason.
func TestQA1082B_DistinctSIDFloodStaysBoundedByCapAndPerIPBudget(t *testing.T) {
	var inflight, maxInflight, calls atomic.Int32
	gate := make(chan struct{})
	s := sidServer(t, func(string) (string, error) {
		calls.Add(1)
		n := inflight.Add(1)
		for {
			m := maxInflight.Load()
			if n <= m || maxInflight.CompareAndSwap(m, n) {
				break
			}
		}
		<-gate
		inflight.Add(-1)
		return "", errDSMSessionInvalid
	})
	g := s.sidGuardFor()
	const ip = "10.40.0.6"
	const flood = 100

	results := make(chan error, flood)
	for i := 0; i < flood; i++ {
		sid := fmt.Sprintf("qa-flood-sid-%04d", i)
		go func() {
			_, err := s.validateUnknownSID(sidRequest(sid, ip, "qa"), sid)
			results <- err
		}()
	}
	// Everything except the 8 parked validations returns without touching DSM.
	var busy, limited, other int
	for i := 0; i < flood-sidValidationInflight; i++ {
		select {
		case err := <-results:
			switch {
			case errors.Is(err, errSIDValidationBusy):
				busy++
			case errors.Is(err, errSIDRateLimited):
				limited++
			default:
				other++
			}
		case <-time.After(5 * time.Second):
			t.Fatalf("only %d of %d refusals arrived", i, flood-sidValidationInflight)
		}
	}
	if inflight.Load() != 8 {
		t.Fatalf("in-flight DSM validations = %d, want exactly 8 (the cap)", inflight.Load())
	}
	close(gate)
	for i := 0; i < sidValidationInflight; i++ {
		if err := <-results; !errors.Is(err, errDSMSessionInvalid) {
			t.Fatalf("a released validation returned %v, want errDSMSessionInvalid", err)
		}
	}
	if maxInflight.Load() != 8 || calls.Load() != 8 {
		t.Fatalf("max concurrent = %d, DSM calls = %d, want 8 and 8", maxInflight.Load(), calls.Load())
	}
	if busy != 22 || limited != 70 || other != 0 {
		t.Fatalf("refusals: busy=%d rate-limited=%d other=%d, want 22 / 70 / 0 (30 pass the budget, 8 hold slots)", busy, limited, other)
	}
	if n := flightCount(g); n != 0 || len(g.sem) != 0 {
		t.Fatalf("after the flood: flights=%d slots held=%d, want 0 and 0", n, len(g.sem))
	}
}

// Red if: the window between "no flight for this SID" and "flight registered" lets a burst
// of requests carrying ONE valid SID be denied: either by the concurrency cap (the first 8
// to pass joinFlight hold every slot before any of them registers a flight) or by the
// per-address budget (more than 30 requests all missed joinFlight before the first leader
// registered). This was the point of the D2 fix. Statistical by nature (the window is a few
// microseconds wide): 200 repetitions of a 64- and a 200-wide start-gated burst, each with a
// fresh SID and address; on 6143f88 it fails in the large majority of runs, on a fix that
// registers the flight atomically with the join it never fails.
func TestQA1082B_SameSIDBurstIsNeverDeniedUnderLoad(t *testing.T) {
	for _, burst := range []int{64, 200} {
		for rep := 0; rep < 100; rep++ {
			burst, rep := burst, rep
			t.Run(fmt.Sprintf("burst%d_rep%02d", burst, rep), func(t *testing.T) {
				t.Parallel() // contention widens the race window, which is the point
				var calls atomic.Int32
				s := sidServer(t, func(string) (string, error) {
					calls.Add(1)
					time.Sleep(30 * time.Millisecond)
					return "ryan", nil
				})
				sid := fmt.Sprintf("qa-sid-load-%03d-%02d", burst, rep)
				ip := "10.41.0.9"
				start := make(chan struct{})
				results := make(chan error, burst)
				for i := 0; i < burst; i++ {
					go func() {
						<-start
						_, err := s.validateUnknownSID(sidRequest(sid, ip, "qa"), sid)
						results <- err
					}()
				}
				close(start)
				denied := map[string]int{}
				for i := 0; i < burst; i++ {
					if err := <-results; err != nil {
						denied[err.Error()]++
					}
				}
				if len(denied) != 0 {
					t.Errorf("valid SID denied: %v (DSM calls: %d)", denied, calls.Load())
				}
			})
		}
	}
}
