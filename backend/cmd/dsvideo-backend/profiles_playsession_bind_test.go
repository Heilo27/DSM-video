package main

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// FRD-002 FR-250, TASK-916 (Worf's finding): a play session serves only the profile it was
// minted for. Before the fix, /playback/{sid}/* and the restart rehydrate path served bytes
// for any session id, so a session minted under the adult profile replayed under the kid
// profile and bypassed the ceiling.

// playbackAs requests path with an optional X-DSVideo-Profile and no Authorization, the way
// a player or a header-carrying client reaches the /playback/{sid}/* routes.
func (w *enfWorld) playbackAs(path, profile string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodGet, path, nil)
	if profile != "" {
		req.Header.Set(profileHeader, profile)
	}
	rec := httptest.NewRecorder()
	w.h.ServeHTTP(rec, req)
	return rec
}

func (w *enfWorld) forgetLiveSession(sid string) {
	w.s.mu.Lock()
	delete(w.s.playSessions, sid)
	w.s.mu.Unlock()
}

func assertRestricted(t *testing.T, what string, rec *httptest.ResponseRecorder) {
	t.Helper()
	if rec.Code != http.StatusForbidden || !strings.Contains(rec.Body.String(), "content_restricted") {
		t.Errorf("%s = %d %q, want 403 content_restricted", what, rec.Code, rec.Body.String())
	}
}

func TestFR250_AdultSessionReplayedUnderKidProfileIsRefused(t *testing.T) {
	w := newEnfWorld(t)
	sid := w.mintSession(t, enfViewers[2], enfMovR) // adult, R title
	stream := "/playback/" + sid + "/stream"

	assertRestricted(t, "kid replaying adult session", w.playbackAs(stream, w.kidID))

	if rec := w.playbackAs(stream, w.ownerID); rec.Code != http.StatusOK || rec.Body.String() != "BYTES-OF-"+enfMovR {
		t.Errorf("minting profile replaying its own session = %d %q, want 200 + bytes", rec.Code, rec.Body.String())
	}
}

func TestFR250_RehydratedSessionKeepsItsMintingProfile(t *testing.T) {
	w := newEnfWorld(t)
	sid := w.mintSession(t, enfViewers[2], enfMovR)
	stream := "/playback/" + sid + "/stream"

	// A restart empties the in-memory map; the next request rehydrates from play_sessions.
	w.forgetLiveSession(sid)
	assertRestricted(t, "kid replaying adult session after restart", w.playbackAs(stream, w.kidID))

	w.forgetLiveSession(sid)
	if rec := w.playbackAs(stream, w.ownerID); rec.Code != http.StatusOK || rec.Body.String() != "BYTES-OF-"+enfMovR {
		t.Errorf("minting profile after restart = %d %q, want 200 + bytes", rec.Code, rec.Body.String())
	}
}

func TestFR250_PreUpgradeSessionRowIsTreatedAsOwnerMinted(t *testing.T) {
	w := newEnfWorld(t)
	var path string
	if err := w.db.QueryRow(`SELECT path FROM items WHERE id = ?`, enfMovR).Scan(&path); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Format(time.RFC3339)
	sid := "ps_legacy_row"
	if _, err := w.db.Exec(`INSERT INTO play_sessions
		(session_id, item_id, path, kind, playback_mode, transcoding, user_id, profile_id, created_at, last_access)
		VALUES(?, ?, ?, 'direct', 0, 0, ?, NULL, ?, ?)`, sid, enfMovR, path, qaAlice.id, now, now); err != nil {
		t.Fatal(err)
	}
	stream := "/playback/" + sid + "/stream"

	assertRestricted(t, "kid replaying a pre-upgrade session", w.playbackAs(stream, w.kidID))
	w.forgetLiveSession(sid)
	if rec := w.playbackAs(stream, w.ownerID); rec.Code != http.StatusOK {
		t.Errorf("owner replaying a pre-upgrade session = %d %q, want 200", rec.Code, rec.Body.String())
	}
}

func TestFR250_HLSSegmentsHoldToTheMintingProfile(t *testing.T) {
	w := newEnfWorld(t)
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "init.mp4"), []byte("INIT"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "segment_00001.m4s"), []byte("SEG"), 0o644); err != nil {
		t.Fatal(err)
	}
	sid := "ps_hls_adult"
	w.s.mu.Lock()
	w.s.playSessions[sid] = PlaySession{ItemID: enfMovR, Kind: "hls", HLSDir: dir,
		CreatedAt: time.Now(), LastAccess: time.Now(), UserID: qaAlice.id, ProfileID: w.ownerID}
	w.s.mu.Unlock()

	for _, name := range []string{"init.mp4", "segment_00001.m4s", "segments/segment_00001.m4s"} {
		p := "/playback/" + sid + "/" + name
		assertRestricted(t, "kid fetching "+name, w.playbackAs(p, w.kidID))
		if rec := w.playbackAs(p, w.ownerID); rec.Code != http.StatusOK {
			t.Errorf("owner fetching %s = %d, want 200", name, rec.Code)
		}
		// AVPlayer sends no header on segment fetches: the session id stays the capability.
		if rec := w.playbackAs(p, ""); rec.Code != http.StatusOK {
			t.Errorf("header-less fetch of %s = %d, want 200", name, rec.Code)
		}
	}
}

func TestFR251_WebAPIStreamRefusesAnAppSessionMintedForAnotherProfile(t *testing.T) {
	w := newEnfWorld(t)
	wsid := pcSession(t, qaAlice) // WebAPI speaks for the FR-221 default: the kid profile
	stream := func(id string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, "/webapi/VideoStation/vtestreaming.cgi/DTV.mov?"+
			url.Values{"_sid": {wsid}, "id": {id}, "method": {"stream"}}.Encode(), nil)
		rec := httptest.NewRecorder()
		w.s.handleWebAPIVTEStreaming(rec, req)
		return rec
	}

	adult := w.mintSession(t, enfViewers[2], enfMovR)
	if rec := stream(adult); rec.Body.String() == "BYTES-OF-"+enfMovR ||
		!strings.Contains(rec.Body.String(), `"code":105`) {
		t.Errorf("WebAPI replay of an adult-minted session = %d %q, want error 105", rec.Code, rec.Body.String())
	}

	kid := w.mintSession(t, enfViewers[0], enfMovG)
	if rec := stream(kid); rec.Body.String() != "BYTES-OF-"+enfMovG {
		t.Errorf("WebAPI stream of a session minted for its own profile = %d %q, want the bytes", rec.Code, rec.Body.String())
	}
}
