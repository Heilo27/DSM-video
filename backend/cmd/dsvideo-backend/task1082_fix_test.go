package main

import (
	"context"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

// TASK-1082 follow-up tests (O'Brien), closing the M-6 and M-13 gaps Worf listed. They pin
// behaviors the fix commit already promised; the pass criterion for D2-R1 itself is Worf's
// TestQA1082B_SameSIDBurstIsNeverDeniedUnderLoad.

// M-6: once a leader's flight exists, followers for that SID are neither rate-limited nor
// refused as busy, however many there are. Deterministic: the leader is held inside the DSM
// call, so every follower provably arrives while the flight is registered. 48 followers from
// ONE address exceed the 30-per-minute budget, so any follower that is charged to it is denied.
// Red if: followers take the per-IP charge or a cap slot instead of joining the flight.
func TestTASK1082_FollowersOfALiveFlightAreNeverChargedOrRefused(t *testing.T) {
	const followers = 48
	release := make(chan struct{})
	var calls atomic.Int32
	s := sidServer(t, func(string) (string, error) {
		calls.Add(1)
		<-release
		return "ryan", nil
	})
	g := s.sidGuardFor()
	const sid, ip = "m6-sid", "10.42.0.7"

	leaderDone := make(chan sidResult, 1)
	go func() {
		acc, err := s.validateUnknownSID(sidRequest(sid, ip, "m6"), sid)
		leaderDone <- sidResult{acc, err}
	}()
	waitFor(t, "the leader's flight to exist", func() bool { return flightCount(g) == 1 })

	var parked atomic.Int32
	out := make(chan sidResult, followers)
	for i := 0; i < followers; i++ {
		go func() {
			acc, err := s.validateUnknownSID(spyRequest(sid, ip, context.Background(), &parked), sid)
			out <- sidResult{acc, err}
		}()
	}
	// Every follower either parks on the flight (reads ctx.Done) or is refused outright.
	waitFor(t, "followers to park or be refused", func() bool { return int(parked.Load())+len(out) >= followers })
	close(release)

	for i := 0; i < followers; i++ {
		select {
		case r := <-out:
			if r.err != nil || r.account != "ryan" {
				t.Errorf("follower %d got (%q, %v), want (ryan, nil)", i, r.account, r.err)
			}
		case <-time.After(10 * time.Second):
			t.Fatalf("follower %d never returned", i)
		}
	}
	if r := <-leaderDone; r.err != nil || r.account != "ryan" {
		t.Errorf("leader got (%q, %v), want (ryan, nil)", r.account, r.err)
	}
	if n := calls.Load(); n != 1 {
		t.Errorf("DSM was called %d times for one SID, want 1", n)
	}
	if n := flightCount(g); n != 0 {
		t.Errorf("%d flight(s) left registered", n)
	}
}

// M-13: collectEmbeddedSubtitles checks the extraction cache against the RESOLVED file (the
// path that passed the media-root check), so a title reached through a symlink lists the
// subtitles cached for its real file.
//
// Limit, stated plainly: os.Stat follows symlinks, so a symlink and its target stat the same
// and this test stays green if collectEmbeddedSubtitles keeps the raw videoPath (mutation
// checked 2026-11-03). The reassignment there is defense in depth against the path changing
// between check and use, which no deterministic test can reach without a seam. What this
// test does pin is the user-visible contract: a symlinked title lists its cached subtitles
// and triggers no re-extraction.
func TestTASK1082_CollectEmbeddedSubtitlesReadsMetaForTheResolvedPath(t *testing.T) {
	w := newEmbeddedSubsWorld(t, false, subVideoH264, subStreamEn)
	w.s.ensureEmbeddedSubs(subTestItemID, w.path, nil)
	w.waitMeta(t, subTestItemID)

	link := filepath.Join(w.movies, "Alias.mkv")
	if err := os.Symlink(w.path, link); err != nil {
		t.Fatal(err)
	}
	tr := w.s.collectEmbeddedSubtitles(subTestItemID, link, 0, nil)
	if len(tr) != 1 || tr[0].Name != "English" {
		t.Fatalf("symlinked path should list the cached English track, got %v", trackNames(tr))
	}
	if n := len(w.ffmpegRuns(t)); n != 1 {
		t.Errorf("a current cache reached through a symlink must not re-extract, ffmpeg runs=%d", n)
	}
}
