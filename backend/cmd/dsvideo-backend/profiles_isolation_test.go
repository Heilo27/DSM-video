package main

// FRD-002 FR-201 / FR-230 / FR-231 isolation, driven through the real router and handlers.
// Expected values are literals.

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

func idsOf(t *testing.T, r qaResp, key string) map[string]bool {
	t.Helper()
	out := map[string]bool{}
	items, _ := r.js[key].([]any)
	for _, it := range items {
		m, _ := it.(map[string]any)
		if id, _ := m["id"].(string); id != "" {
			out[id] = true
		}
	}
	return out
}

// AC-002-12 / FR-201 / FR-230. Profiles A and B in one account. Progress and watchlist written
// under A appear under A and under NONE of B's reads: /progress, /progress/all,
// /items?filter=justWatched, /watchlist, /watchlist/{id}, /suggested. B's own writes do not
// leak back into A. Same-item writes by both keep separate positions. Red if any of those
// handlers is still keyed by account instead of profile.
func TestAC00212_ProgressAndWatchlistAreIsolatedBetweenProfiles(t *testing.T) {
	e := newQAEnv(t)
	a := e.setOwnerPin(qaAlice, "0420")
	b := e.mustCreate(qaAlice, "0420", "Bee", 4, nil) // level 4: visibility filtering cannot explain any difference
	for _, id := range []string{"h1", "h2", "h3"} {
		e.seedItem(id, "Horror", sp("R"))
	}
	e.seedItem("c1", "Comedy", sp("PG-13"))
	e.seedItem("c2", "Comedy", sp("PG-13"))
	e.seedItem("shared", "", sp("PG-13")) // no genre: must not become the suggestion seed (same-second tie)

	post := func(item, profile string, pos int) {
		wantOK(t, e.do(qaAlice, "POST", "/items/"+item+"/progress", jb(map[string]any{"positionSeconds": pos, "durationSeconds": 3000}), profile), 200)
	}
	post("h1", a, 111)
	post("shared", a, 500)
	wantOK(t, e.do(qaAlice, "POST", "/watchlist/h2", "", a), 200)

	// A sees its own data.
	pa := e.do(qaAlice, "GET", "/progress/all", "", a)
	if prog, _ := pa.js["progress"].(map[string]any); len(prog) != 2 || prog["h1"] == nil || prog["shared"] == nil {
		t.Fatalf("A's own progress missing: %s", pa.raw)
	}

	// B sees none of it, on every read path.
	if r := e.do(qaAlice, "GET", "/progress/all", "", b); len(r.js["progress"].(map[string]any)) != 0 {
		t.Errorf("/progress/all leaks A's progress to B: %s", r.raw)
	}
	r := e.do(qaAlice, "GET", "/progress?ids=h1,shared,c1", "", b)
	if prog, _ := r.js["progress"].(map[string]any); len(prog) != 0 {
		t.Errorf("/progress batch leaks A's progress to B: %s", r.raw)
	}
	if r := e.do(qaAlice, "GET", "/items?filter=justWatched", "", b); r.num("total") != 0 || len(idsOf(t, r, "items")) != 0 {
		t.Errorf("justWatched leaks A's history to B: %s", r.raw)
	}
	if r := e.do(qaAlice, "GET", "/watchlist", "", b); len(idsOf(t, r, "items")) != 0 {
		t.Errorf("/watchlist leaks A's list to B: %s", r.raw)
	}
	if r := e.do(qaAlice, "GET", "/watchlist/h2", "", b); r.js["inWatchlist"] != false {
		t.Errorf("/watchlist/h2 says B has A's entry: %s", r.raw)
	}
	if r := e.do(qaAlice, "GET", "/suggested", "", b); len(idsOf(t, r, "items")) != 0 || r.str("genre") != "" {
		t.Errorf("/suggested for B is seeded from A's history: %s", r.raw)
	}
	// Item listings carry per-item progress: B must not see A's position on /items either.
	li := e.do(qaAlice, "GET", "/items?libraryId=lib1", "", b)
	for _, it := range li.js["items"].([]any) {
		m := it.(map[string]any)
		if m["id"] == "shared" || m["id"] == "h1" {
			if p, ok := m["progress"].(map[string]any); ok && len(p) > 0 && p["positionSeconds"] != float64(0) && p["positionSeconds"] != nil {
				t.Errorf("/items shows A's position on %v to B: %v", m["id"], p)
			}
		}
	}

	// A's suggested rail IS seeded from A's history (positive control: the filter is not simply
	// "return nothing"), and excludes what A is already watching.
	sa := e.do(qaAlice, "GET", "/suggested", "", a)
	got := idsOf(t, sa, "items")
	if sa.str("genre") != "Horror" || !got["h2"] || !got["h3"] || got["h1"] || len(got) != 2 {
		t.Errorf("A's /suggested = %s, want Horror with h2,h3 (not the watched h1)", sa.raw)
	}

	// B writes: different item, and the SAME item at a different position.
	post("c1", b, 77)
	post("shared", b, 9)
	wantOK(t, e.do(qaAlice, "POST", "/watchlist/c2", "", b), 200)

	pb := e.do(qaAlice, "GET", "/progress/all", "", b)
	progB, _ := pb.js["progress"].(map[string]any)
	if len(progB) != 2 || progB["c1"] == nil || progB["shared"] == nil || progB["h1"] != nil {
		t.Errorf("B's progress = %s, want exactly c1 and shared", pb.raw)
	}
	if m, _ := progB["shared"].(map[string]any); m == nil || m["positionSeconds"] != float64(9) {
		t.Errorf("B's position on 'shared' = %v, want 9 (not A's 500)", progB["shared"])
	}
	pa = e.do(qaAlice, "GET", "/progress/all", "", a)
	progA, _ := pa.js["progress"].(map[string]any)
	if len(progA) != 2 || progA["c1"] != nil {
		t.Errorf("B's write leaked into A: %s", pa.raw)
	}
	if m, _ := progA["shared"].(map[string]any); m == nil || m["positionSeconds"] != float64(500) {
		t.Errorf("A's position on 'shared' = %v, want 500 (B's write overwrote it)", progA["shared"])
	}
	if got := idsOf(t, e.do(qaAlice, "GET", "/watchlist", "", a), "items"); len(got) != 1 || !got["h2"] {
		t.Errorf("A's watchlist = %v, want only h2", got)
	}
	if got := idsOf(t, e.do(qaAlice, "GET", "/watchlist", "", b), "items"); len(got) != 1 || !got["c2"] {
		t.Errorf("B's watchlist = %v, want only c2", got)
	}
	// B's suggestions follow B's history (Comedy), not A's.
	if sb := e.do(qaAlice, "GET", "/suggested", "", b); sb.str("genre") != "Comedy" || !idsOf(t, sb, "items")["c2"] {
		t.Errorf("B's /suggested = %s, want Comedy incl. c2", sb.raw)
	}
	// Removing from one list leaves the other.
	wantOK(t, e.do(qaAlice, "DELETE", "/watchlist/h2", "", b), 200) // B never had h2
	if got := idsOf(t, e.do(qaAlice, "GET", "/watchlist", "", a), "items"); !got["h2"] {
		t.Errorf("B's DELETE of an entry B never had removed A's h2")
	}
	// Database truth: one row per (item, profile), keyed by the right profile, and the legacy
	// account column is the account.
	if n := e.count(`SELECT COUNT(*) FROM progress WHERE item_id='shared' AND user_id='u_alice'`); n != 2 {
		t.Errorf("'shared' has %d progress rows for the account, want one per profile (2)", n)
	}
	if n := e.count(`SELECT COUNT(*) FROM progress WHERE profile_id NOT IN (SELECT id FROM profiles)`); n != 0 {
		t.Errorf("%d progress rows point at no profile", n)
	}
}

// FR-201: a second ACCOUNT is isolated too, including from a profile header it does not own.
func TestAC00212_OtherAccountNeverSeesProfileData(t *testing.T) {
	e := newQAEnv(t)
	a := e.setOwnerPin(qaAlice, "0420")
	bobOwner := e.ownerID(qaBob)
	e.seedItem("x1", "Drama", sp("PG"))
	wantOK(t, e.do(qaAlice, "POST", "/items/x1/progress", jb(map[string]any{"positionSeconds": 5, "durationSeconds": 60}), a), 200)
	wantOK(t, e.do(qaAlice, "POST", "/watchlist/x1", "", a), 200)

	if r := e.do(qaBob, "GET", "/progress/all", "", bobOwner); len(r.js["progress"].(map[string]any)) != 0 {
		t.Errorf("bob sees alice's progress: %s", r.raw)
	}
	if got := idsOf(t, e.do(qaBob, "GET", "/watchlist", "", ""), "items"); len(got) != 0 {
		t.Errorf("bob sees alice's watchlist: %v", got)
	}
	// Bob writing with ALICE's profile id must be refused, not written into alice's data.
	r := e.do(qaBob, "POST", "/items/x1/progress", jb(map[string]any{"positionSeconds": 999, "durationSeconds": 1000}), a)
	wantErr(t, r, 403, "unknown_profile")
	r = e.do(qaBob, "POST", "/watchlist/x1", "", a)
	wantErr(t, r, 403, "unknown_profile")
	pa := e.do(qaAlice, "GET", "/progress/all", "", a)
	if m, _ := pa.js["progress"].(map[string]any)["x1"].(map[string]any); m == nil || m["positionSeconds"] != float64(5) {
		t.Errorf("alice's position was overwritten across accounts: %s", pa.raw)
	}
}

// FR-231 / AC-002-25 (progress half): a restricted profile's progress write for a title ABOVE
// its ceiling is accepted and stored under that profile. (The watchlist 403 content_restricted
// and the hiding of such rows on read are FR-250/FR-207 enforcement, TASK-916 part B; not
// asserted here.) Red if the progress route gains a visibility gate or drops the write.
func TestAC00225_ProgressAcceptedAboveCeiling(t *testing.T) {
	e := newQAEnv(t)
	e.setOwnerPin(qaAlice, "0420")
	kid := e.mustCreate(qaAlice, "0420", "Kid", 1, nil)
	e.seedItem("r1", "Horror", sp("R"))
	e.seedItem("u1", "Drama", nil) // unrated = level 4

	for _, id := range []string{"r1", "u1"} {
		wantOK(t, e.do(qaAlice, "POST", "/items/"+id+"/progress", jb(map[string]any{"positionSeconds": 30, "durationSeconds": 600}), kid), 200)
	}
	if n := e.count(`SELECT COUNT(*) FROM progress WHERE profile_id=? AND position_seconds=30`, kid); n != 2 {
		t.Errorf("kid has %d stored progress rows, want 2 (r1,u1)", n)
	}
	if n := e.count(`SELECT COUNT(*) FROM progress WHERE profile_id<>? OR user_id<>'u_alice'`, kid); n != 0 {
		t.Errorf("%d progress rows stored under another profile/account", n)
	}
}

// WebAPI plane (SYNO.VideoStation2.WatchStatus update), the DS Video app's own progress write.
// After the profiles migration `progress` is keyed (item_id, profile_id) with profile_id NOT
// NULL; a write that still names (item_id, user_id) cannot succeed. FR-230: progress belongs
// to a profile; FR-221: no header -> the fallback profile. Red until the handler writes to the
// resolved profile.
func TestFR230_WebAPIWatchStatusWritesToTheFallbackProfile(t *testing.T) {
	e := newQAEnv(t)
	owner := e.ownerID(qaAlice)
	e.seedItem("w1", "Drama", sp("PG"))

	const sid = "qa-webapi-sid-1"
	webAPISessions.mu.Lock()
	webAPISessions.sessions[sid] = &WebAPISession{SID: sid, UserID: qaAlice.id, Username: qaAlice.name, Token: "x", DeviceID: "did_qa", CreatedAt: time.Now()}
	webAPISessions.mu.Unlock()
	t.Cleanup(func() {
		webAPISessions.mu.Lock()
		delete(webAPISessions.sessions, sid)
		webAPISessions.mu.Unlock()
	})
	m := getOrCreateMapping(sid)
	m.mu.Lock()
	m.movieIDs["42"] = "w1"
	m.mu.Unlock()

	q := url.Values{"_sid": {sid}, "id": {"42"}, "time": {"123"}, "total_time": {"3000"}}
	req := httptest.NewRequest(http.MethodGet, "/webapi/entry.cgi?"+q.Encode(), nil)
	rec := httptest.NewRecorder()
	e.s.handleWebAPIWatchStatus(rec, req, "update")

	if rec.Code != 200 || !strings.Contains(rec.Body.String(), `"success":true`) {
		t.Errorf("WatchStatus update did not succeed: %d %s", rec.Code, rec.Body.String())
	}
	if n := e.count(`SELECT COUNT(*) FROM progress WHERE item_id='w1' AND profile_id=? AND position_seconds=123`, owner); n != 1 {
		t.Errorf("the DS Video app's position (123s on w1) was not stored on alice's owner profile (rows=%d)", n)
	}
}
