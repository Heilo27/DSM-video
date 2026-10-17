package main

// FRD-002 §2-§4 verification: profile limit, no-header fallback, unknown_profile, owner-PIN
// gate, owner immutability, field validation, age-level table. Written from the FRD/API doc.
// Expected values are literals. Each test says which change would turn it red.

import (
	"bytes"
	"encoding/json"
	"net/http"
	"reflect"
	"strings"
	"testing"
)

// AC-002-11 / FR-200. Given an account with 4 profiles, when a fifth is created, then
// 409 profile_limit_reached and no row. Red if: limit becomes 5, check is skipped, or the
// row is inserted before the check. Boundary: the 4th (max) succeeds, the 5th (max+1) fails,
// and after deleting one a new one fits again (count delta + identity, not just status).
func TestAC00211_FifthProfileRefusedAndNoRowCreated(t *testing.T) {
	e := newQAEnv(t)
	e.setOwnerPin(qaAlice, "0420")
	if n := e.profileRowCount(qaAlice.id); n != 1 {
		t.Fatalf("precondition: want 1 profile (owner), have %d", n)
	}
	e.mustCreate(qaAlice, "0420", "Maya", 2, nil)
	e.mustCreate(qaAlice, "0420", "Theo", 3, nil)
	if n := e.profileRowCount(qaAlice.id); n != 3 {
		t.Fatalf("after two creates want 3 profiles, have %d", n)
	}
	fourth := e.create(qaAlice, "0420", "Zed", 1, nil)
	wantOK(t, fourth, 201) // max (4 incl. owner) is allowed
	if n := e.profileRowCount(qaAlice.id); n != 4 {
		t.Fatalf("want 4 profiles at the limit, have %d", n)
	}

	fifth := e.create(qaAlice, "0420", "Fifth", 1, nil)
	wantErr(t, fifth, 409, "profile_limit_reached")
	if n := e.profileRowCount(qaAlice.id); n != 4 {
		t.Errorf("a refused fifth profile changed the row count: %d, want 4", n)
	}
	if e.count(`SELECT COUNT(*) FROM profiles WHERE user_id=? AND name='Fifth'`, qaAlice.id) != 0 {
		t.Errorf("row named Fifth exists despite 409")
	}
	// Another account is not affected by alice's limit (negative control for a global count).
	e.setOwnerPin(qaBob, "1357")
	wantOK(t, e.create(qaBob, "1357", "Kid", 1, nil), 201)

	// Freeing a slot lets a new one in: the limit is on live profiles.
	zed := fourth.str("id")
	wantOK(t, e.do(qaAlice, "DELETE", "/profiles/"+zed, jb(map[string]any{"ownerPin": "0420"}), ""), 200)
	wantOK(t, e.create(qaAlice, "0420", "Fifth", 1, nil), 201)
	if n := e.profileRowCount(qaAlice.id); n != 4 {
		t.Errorf("want 4 profiles after delete+create, have %d", n)
	}
	// The refused request with a wrong owner PIN must not get a limit answer first (PIN gate
	// before anything else, FR-211) - it is pin_incorrect.
	wantErr(t, e.create(qaAlice, "9999", "Sixth", 1, nil), 403, "pin_incorrect")
}

// probe is a stand-in downstream handler for resolver-only checks.
var qaProbe = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(200)
	_, _ = w.Write([]byte(`{"probe":"ok"}`))
})

// AC-002-15 / FR-221 / FR-222. No header: owner-only -> owner; restricted at 3 and 1 -> the
// level-1; two level-1 -> earlier created. The response header always names the profile.
// Red if: fallback picks the owner whenever one exists, picks the highest level, ties by id
// order, or the response header is not set.
func TestAC00215_NoHeaderFallbackAndResponseHeader(t *testing.T) {
	e := newQAEnv(t)
	owner := e.setOwnerPin(qaAlice, "0420")

	check := func(label, want string) {
		t.Helper()
		// real route (strict resolver) and the lenient /profiles route both name it
		r := e.do(qaAlice, "GET", "/libraries", "", "")
		if r.code != 200 {
			t.Fatalf("%s: GET /libraries = %d %s", label, r.code, r.raw)
		}
		if got := r.hdr.Get("X-DSVideo-Profile"); got != want {
			t.Errorf("%s: /libraries X-DSVideo-Profile = %q, want %q", label, got, want)
		}
		p := e.do(qaAlice, "GET", "/profiles", "", "")
		if got := p.hdr.Get("X-DSVideo-Profile"); got != want {
			t.Errorf("%s: /profiles X-DSVideo-Profile = %q, want %q", label, got, want)
		}
		if got := p.str("activeProfileId"); got != want {
			t.Errorf("%s: activeProfileId = %q, want %q", label, got, want)
		}
	}

	check("owner only", owner)

	adult := e.mustCreate(qaAlice, "0420", "Adult2", 4, nil) // unrestricted non-owner
	check("owner + level-4 non-owner (nothing restricted)", owner)

	teen := e.mustCreate(qaAlice, "0420", "Teen", 3, nil)
	check("restricted at 3 only", teen)

	kid := e.mustCreate(qaAlice, "0420", "Kid", 1, nil)
	check("restricted at 3 and 1", kid)

	// Header present and valid wins over the fallback (positive control that the header is read).
	r := e.do(qaAlice, "GET", "/libraries", "", teen)
	if got := r.hdr.Get("X-DSVideo-Profile"); got != teen {
		t.Errorf("explicit header teen: response header %q, want %q", got, teen)
	}
	r = e.do(qaAlice, "GET", "/libraries", "", owner)
	if got := r.hdr.Get("X-DSVideo-Profile"); got != owner {
		t.Errorf("explicit header owner: response header %q, want %q", got, owner)
	}
	_ = adult
}

// FR-221 tie: two level-1 profiles -> the earlier-created. created_at is second-granular, so
// the order is also driven apart explicitly: the SECOND-inserted row is given the EARLIER
// timestamp and must win (red if ties go to insertion order, id order or alphabetical name).
func TestAC00215_TieGoesToEarlierCreated(t *testing.T) {
	e := newQAEnv(t)
	e.setOwnerPin(qaAlice, "0420")
	first := e.mustCreate(qaAlice, "0420", "Zoe", 1, nil)  // name sorts last
	second := e.mustCreate(qaAlice, "0420", "Abe", 1, nil) // name sorts first
	third := e.mustCreate(qaAlice, "0420", "Mid", 2, nil)  // different level
	_ = third

	get := func() string {
		r := e.do(qaAlice, "GET", "/libraries", "", "")
		return r.hdr.Get("X-DSVideo-Profile")
	}
	// Same second: creation order decides.
	if _, err := e.db.Exec(`UPDATE profiles SET created_at='2026-10-17T10:00:00Z' WHERE user_id=? AND is_owner=0`, qaAlice.id); err != nil {
		t.Fatal(err)
	}
	if got := get(); got != first {
		t.Errorf("same-timestamp tie: served for %s, want the first-created %s", got, first)
	}
	// Distinct timestamps: the earlier timestamp wins even though it was inserted second.
	if _, err := e.db.Exec(`UPDATE profiles SET created_at='2026-10-17T10:00:00Z' WHERE id=?`, second); err != nil {
		t.Fatal(err)
	}
	if _, err := e.db.Exec(`UPDATE profiles SET created_at='2026-10-17T11:00:00Z' WHERE id=?`, first); err != nil {
		t.Fatal(err)
	}
	if got := get(); got != second {
		t.Errorf("earlier created_at must win: served for %s, want %s", got, second)
	}
	// Lowest level beats creation order (level 1 beats an earlier-created level 2).
	if _, err := e.db.Exec(`UPDATE profiles SET created_at='2026-10-17T09:00:00Z' WHERE id=?`, third); err != nil {
		t.Fatal(err)
	}
	if got := get(); got == third {
		t.Errorf("served for level-2 profile %s although level-1 profiles exist", got)
	}
}

// FR-221 consequence: a no-header request writes to the most restricted profile, and the
// owner's data is untouched (needs the per-profile handlers; red until they are wired).
func TestAC00215_NoHeaderProgressIsWrittenToTheFallbackProfile(t *testing.T) {
	e := newQAEnv(t)
	owner := e.setOwnerPin(qaAlice, "0420")
	kid := e.mustCreate(qaAlice, "0420", "Kid", 1, nil)
	e.seedItem("i1", "Family", sp("G"))

	wantOK(t, e.do(qaAlice, "POST", "/items/i1/progress", jb(map[string]any{"positionSeconds": 77, "durationSeconds": 900}), ""), 200)

	asKid := e.do(qaAlice, "GET", "/progress/all", "", kid)
	asOwner := e.do(qaAlice, "GET", "/progress/all", "", owner)
	if prog, _ := asKid.js["progress"].(map[string]any); len(prog) != 1 || prog["i1"] == nil {
		t.Errorf("kid should hold the no-header write; got %s", asKid.raw)
	}
	if prog, _ := asOwner.js["progress"].(map[string]any); len(prog) != 0 {
		t.Errorf("owner must not see the kid-fallback write; got %s", asOwner.raw)
	}
}

// AC-002-16 / FR-220. Another account's id and a deleted id give 403 unknown_profile with
// byte-identical bodies on every strict route; /profiles with a deleted id still works and
// names the profile it actually used. Red if the two cases are distinguishable, if the
// status differs, or if /profiles is made strict.
func TestAC00216_UnknownProfileIsIndistinguishableAndProfilesRoutesFallBack(t *testing.T) {
	e := newQAEnv(t)
	aOwner := e.setOwnerPin(qaAlice, "0420")
	bOwner := e.setOwnerPin(qaBob, "1357")
	deleted := e.mustCreate(qaAlice, "0420", "Gone", 2, nil)
	wantOK(t, e.do(qaAlice, "DELETE", "/profiles/"+deleted, jb(map[string]any{"ownerPin": "0420"}), ""), 200)

	for _, route := range []string{"/libraries", "/items?libraryId=lib1", "/watchlist", "/progress/all", "/suggested", "/just-added"} {
		other := e.do(qaAlice, "GET", route, "", bOwner)
		gone := e.do(qaAlice, "GET", route, "", deleted)
		never := e.do(qaAlice, "GET", route, "", "pf_neverexisted")
		wantErr(t, other, 403, "unknown_profile")
		wantErr(t, gone, 403, "unknown_profile")
		wantErr(t, never, 403, "unknown_profile")
		if !bytes.Equal(other.raw, gone.raw) || !bytes.Equal(other.raw, never.raw) {
			t.Errorf("%s: bodies differ: other-account=%q deleted=%q never=%q", route, other.raw, gone.raw, never.raw)
		}
		if other.hdr.Get("Content-Type") != gone.hdr.Get("Content-Type") {
			t.Errorf("%s: content types differ", route)
		}
		// positive control: own owner id works on the same route
		if ok := e.do(qaAlice, "GET", route, "", aOwner); ok.code == 403 {
			t.Errorf("%s: own profile header refused: %s", route, ok.raw)
		}
	}
	// The other account's id used in the other direction is refused too.
	wantErr(t, e.do(qaBob, "GET", "/libraries", "", aOwner), 403, "unknown_profile")

	// Management routes fall back instead of refusing, and say which profile they used.
	for _, bad := range []string{deleted, bOwner, "pf_neverexisted"} {
		r := e.do(qaAlice, "GET", "/profiles", "", bad)
		if r.code != 200 {
			t.Errorf("GET /profiles with stale id %q = %d %s, want 200 fallback", bad, r.code, r.raw)
			continue
		}
		if r.hdr.Get("X-DSVideo-Profile") != aOwner || r.str("activeProfileId") != aOwner {
			t.Errorf("fallback should name owner %s: header=%q active=%q", aOwner, r.hdr.Get("X-DSVideo-Profile"), r.str("activeProfileId"))
		}
		if raw, _ := r.js["profiles"].([]any); len(raw) != 1 {
			t.Errorf("fallback listing has %d profiles, want alice's 1 (never another account's)", len(raw))
		}
	}
	// age-levels also lives under /profiles and must not 403 on a stale id.
	if r := e.do(qaAlice, "GET", "/profiles/age-levels", "", deleted); r.code != 200 {
		t.Errorf("GET /profiles/age-levels with stale id = %d %s, want 200", r.code, r.raw)
	}
}

// AC-002-17 / FR-211 / FR-217. Create, edit and delete without ownerPin -> 403
// owner_pin_required; wrong ownerPin -> 403 pin_incorrect with attemptsRemaining; none is 401
// (the harness fails any 401). Each refusal must leave the data untouched. Red if any
// management route skips the gate, or answers 401, or applies the change before checking.
func TestAC00217_ManagementNeedsOwnerPin_NoChangeOnRefusal(t *testing.T) {
	e := newQAEnv(t)
	e.setOwnerPin(qaAlice, "0420")
	kid := e.mustCreate(qaAlice, "0420", "Kid", 1, nil)
	before := e.profileRowCount(qaAlice.id)

	missing := []struct{ label, method, path, body string }{
		{"create", "POST", "/profiles", jb(map[string]any{"name": "New", "maxAgeLevel": 2})},
		{"create null pin", "POST", "/profiles", jb(map[string]any{"ownerPin": nil, "name": "New", "maxAgeLevel": 2})},
		{"edit name", "PATCH", "/profiles/" + kid, jb(map[string]any{"name": "Hacked"})},
		{"edit level", "PATCH", "/profiles/" + kid, jb(map[string]any{"maxAgeLevel": 4})},
		{"edit set pin", "PATCH", "/profiles/" + kid, jb(map[string]any{"pin": "1111"})},
		{"edit clear pin", "PATCH", "/profiles/" + kid, jb(map[string]any{"pin": nil})},
		{"delete empty body", "DELETE", "/profiles/" + kid, ""},
		{"delete json body without pin", "DELETE", "/profiles/" + kid, "{}"},
	}
	for _, c := range missing {
		wantErr(t, e.do(qaAlice, c.method, c.path, c.body, ""), 403, "owner_pin_required")
	}

	wrong := []struct{ label, method, path, body string }{
		{"create", "POST", "/profiles", jb(map[string]any{"ownerPin": "9999", "name": "New", "maxAgeLevel": 2})},
		{"edit", "PATCH", "/profiles/" + kid, jb(map[string]any{"ownerPin": "9999", "name": "Hacked"})},
		{"delete", "DELETE", "/profiles/" + kid, jb(map[string]any{"ownerPin": "9999"})},
	}
	for i, c := range wrong {
		r := e.do(qaAlice, c.method, c.path, c.body, "")
		wantErr(t, r, 403, "pin_incorrect")
		if got, want := r.num("attemptsRemaining"), 4-i; got != want {
			t.Errorf("%s: attemptsRemaining = %d, want %d (shared counter, FR-215)", c.label, got, want)
		}
		if _, ok := r.js["attemptsRemaining"]; !ok {
			t.Errorf("%s: body lacks attemptsRemaining: %s", c.label, r.raw)
		}
	}

	if n := e.profileRowCount(qaAlice.id); n != before {
		t.Errorf("refused management calls changed the profile count %d -> %d", before, n)
	}
	k := e.profileByName(qaAlice, "Kid")
	if k == nil || k["id"] != kid || k["maxAgeLevel"] != float64(1) || k["hasPin"] != false {
		t.Errorf("kid profile mutated by a refused call: %v", k)
	}
	if e.profileByName(qaAlice, "New") != nil || e.profileByName(qaAlice, "Hacked") != nil {
		t.Errorf("a refused call created or renamed a profile")
	}

	// Positive control: the correct PIN performs the same edit, so the refusals above were
	// caused by the gate and not by some other validation failure.
	r := e.do(qaAlice, "PATCH", "/profiles/"+kid, jb(map[string]any{"ownerPin": "0420", "name": "Kiddo"}), "")
	wantOK(t, r, 200)
	if r.str("name") != "Kiddo" {
		t.Errorf("edit with correct PIN did not rename: %s", r.raw)
	}
}

// AC-002-18 part 1 / FR-212. Owner with no PIN: creating a second profile -> 409
// owner_pin_not_set, no row; setting the first PIN needs no ownerPin; a second PIN change
// afterwards does.
func TestAC00218_OwnerPinNotSetBlocksSecondProfile_FirstPinNeedsNoOwnerPin(t *testing.T) {
	e := newQAEnv(t)
	owner := e.ownerID(qaAlice)
	for _, body := range []map[string]any{
		{"name": "Kid", "maxAgeLevel": 1},
		{"ownerPin": "0420", "name": "Kid", "maxAgeLevel": 1}, // a PIN offered while none is set proves nothing
		{"ownerPin": "", "name": "Kid", "maxAgeLevel": 1},
	} {
		wantErr(t, e.do(qaAlice, "POST", "/profiles", jb(body), ""), 409, "owner_pin_not_set")
	}
	if n := e.profileRowCount(qaAlice.id); n != 1 {
		t.Fatalf("owner_pin_not_set still created a row: %d profiles", n)
	}

	r := e.do(qaAlice, "PATCH", "/profiles/"+owner, jb(map[string]any{"pin": "0420"}), "")
	wantOK(t, r, 200)
	if r.js["hasPin"] != true || r.js["isOwner"] != true {
		t.Errorf("first owner PIN: %s", r.raw)
	}
	// Now that a PIN exists, changing it needs the current one.
	wantErr(t, e.do(qaAlice, "PATCH", "/profiles/"+owner, jb(map[string]any{"pin": "1111"}), ""), 403, "owner_pin_required")
	wantErr(t, e.do(qaAlice, "PATCH", "/profiles/"+owner, jb(map[string]any{"ownerPin": "9999", "pin": "1111"}), ""), 403, "pin_incorrect")
	// ...and the PIN is still 0420.
	wantOK(t, e.do(qaAlice, "POST", "/profiles/"+owner+"/pin/verify", jb(map[string]any{"pin": "0420"}), ""), 200)
	wantOK(t, e.create(qaAlice, "0420", "Kid", 1, nil), 201)
}

// AC-002-18 part 2 / FR-204 / FR-212. With other profiles present: clearing the owner's PIN,
// lowering the owner's level, deleting the owner -> 409 owner_profile_immutable, state
// unchanged. Boundaries: raising/keeping the owner at 4 is fine; clearing the PIN with no
// other profile left is allowed; and then a second profile is blocked again.
func TestAC00218_OwnerProfileImmutable(t *testing.T) {
	e := newQAEnv(t)
	owner := e.setOwnerPin(qaAlice, "0420")
	kid := e.mustCreate(qaAlice, "0420", "Kid", 1, nil)
	// OC-2028: the owner has progress and a watchlist entry that the refused DELETE must not touch.
	e.seedItem("o1", "", sp("R"))
	e.seedItem("o2", "", sp("PG"))
	wantOK(t, e.do(qaAlice, "POST", "/items/o1/progress", jb(map[string]any{"positionSeconds": 1234, "durationSeconds": 3000}), owner), 200)
	wantOK(t, e.do(qaAlice, "POST", "/watchlist/o2", "", owner), 200)

	wantErr(t, e.do(qaAlice, "PATCH", "/profiles/"+owner, jb(map[string]any{"ownerPin": "0420", "pin": nil}), ""), 409, "owner_profile_immutable")
	for _, lv := range []int{3, 2, 1} {
		wantErr(t, e.do(qaAlice, "PATCH", "/profiles/"+owner, jb(map[string]any{"ownerPin": "0420", "maxAgeLevel": lv}), ""), 409, "owner_profile_immutable")
	}
	wantErr(t, e.do(qaAlice, "DELETE", "/profiles/"+owner, jb(map[string]any{"ownerPin": "0420"}), ""), 409, "owner_profile_immutable")
	// OC-2028 full "then": owner's progress AND watchlist unchanged after the refused DELETE,
	// read back through the API and the table. Red if the delete cascade (progress/watchlist
	// rows by profile_id) runs before the owner check, or the check is removed.
	if n := e.count(`SELECT COUNT(*) FROM progress WHERE profile_id=?`, owner); n != 1 {
		t.Errorf("owner progress rows = %d after refused DELETE, want 1", n)
	}
	if n := e.count(`SELECT COUNT(*) FROM watchlist WHERE profile_id=?`, owner); n != 1 {
		t.Errorf("owner watchlist rows = %d after refused DELETE, want 1", n)
	}
	pa := e.do(qaAlice, "GET", "/progress/all", "", owner)
	if prog, _ := pa.js["progress"].(map[string]any); len(prog) != 1 {
		t.Errorf("owner /progress/all = %s, want exactly o1", pa.raw)
	} else if m, _ := prog["o1"].(map[string]any); m == nil || m["positionSeconds"] != float64(1234) {
		t.Errorf("owner's o1 position = %v, want 1234", prog["o1"])
	}
	if got := idsOf(t, e.do(qaAlice, "GET", "/watchlist", "", owner), "items"); len(got) != 1 || !got["o2"] {
		t.Errorf("owner's watchlist = %v, want only o2", got)
	}

	var found map[string]any
	for _, p := range e.profiles(qaAlice) {
		if p["id"] == owner {
			found = p
		}
	}
	if found == nil || found["maxAgeLevel"] != float64(4) || found["hasPin"] != true || found["isOwner"] != true {
		t.Errorf("owner state changed by refused calls: %v", found)
	}
	if n := e.profileRowCount(qaAlice.id); n != 2 {
		t.Errorf("profile count %d, want 2 (owner + kid)", n)
	}
	// still verifies with the original PIN
	wantOK(t, e.do(qaAlice, "POST", "/profiles/"+owner+"/pin/verify", jb(map[string]any{"pin": "0420"}), ""), 200)

	// Keeping the owner at level 4 and renaming it are allowed.
	r := e.do(qaAlice, "PATCH", "/profiles/"+owner, jb(map[string]any{"ownerPin": "0420", "maxAgeLevel": 4, "name": "Boss"}), "")
	wantOK(t, r, 200)

	// Remove the last other profile; now the owner PIN may be cleared (no one to protect),
	// after which FR-212 blocks a new profile again.
	wantOK(t, e.do(qaAlice, "DELETE", "/profiles/"+kid, jb(map[string]any{"ownerPin": "0420"}), ""), 200)
	r = e.do(qaAlice, "PATCH", "/profiles/"+owner, jb(map[string]any{"ownerPin": "0420", "pin": nil}), "")
	wantOK(t, r, 200)
	if r.js["hasPin"] != false {
		t.Errorf("owner PIN not cleared: %s", r.raw)
	}
	wantErr(t, e.create(qaAlice, "0420", "Again", 1, nil), 409, "owner_pin_not_set")
}

// FR-203 / API doc field validation. Each invalid value is refused with its own code and
// creates nothing. Boundaries are tested on both sides. Red if a validator is loosened or
// returns a different code.
func TestFR203_FieldValidation(t *testing.T) {
	e := newQAEnv(t)
	e.setOwnerPin(qaAlice, "0420")
	base := func(over map[string]any) qaResp {
		body := map[string]any{"ownerPin": "0420", "name": "Probe", "maxAgeLevel": 2}
		for k, v := range over {
			if v == "<<delete>>" {
				delete(body, k)
			} else {
				body[k] = v
			}
		}
		return e.do(qaAlice, "POST", "/profiles", jb(body), "")
	}
	rows := func() int { return e.profileRowCount(qaAlice.id) }

	t.Run("invalid_avatar", func(t *testing.T) {
		for _, a := range []any{"", "has space", "bad!", "../etc", "é", "a/b", "fox\n", strings.Repeat("a", 33), strings.Repeat("a", 64), 5, true, []string{"x"}} {
			wantErr(t, base(map[string]any{"avatar": a}), 400, "invalid_avatar")
		}
		if rows() != 1 {
			t.Errorf("invalid avatar created a profile")
		}
		// boundaries: 1 and 32 characters, every allowed class
		for i, a := range []string{"a", "Z", "7", "-", "_", strings.Repeat("a", 32), "fox-Owl_9"} {
			r := base(map[string]any{"avatar": a, "name": "Av" + string(rune('A'+i))})
			wantOK(t, r, 201)
			if r.str("avatar") != a {
				t.Errorf("avatar %q stored/returned as %q", a, r.str("avatar"))
			}
			if i > 0 { // free the slot (account limit is 4); keep "AvA" for the edit subtest
				wantOK(t, e.do(qaAlice, "DELETE", "/profiles/"+r.str("id"), jb(map[string]any{"ownerPin": "0420"}), ""), 200)
			}
		}
	})

	t.Run("avatar null and absent are accepted", func(t *testing.T) {
		a := base(map[string]any{"avatar": nil, "name": "NullAv"})
		wantOK(t, a, 201)
		b := base(map[string]any{"avatar": "<<delete>>", "name": "NoAv"})
		wantOK(t, b, 201)
		for _, id := range []string{a.str("id"), b.str("id")} {
			wantOK(t, e.do(qaAlice, "DELETE", "/profiles/"+id, jb(map[string]any{"ownerPin": "0420"}), ""), 200)
		}
	})

	t.Run("invalid_avatar on edit, null clears", func(t *testing.T) {
		id := e.profileByName(qaAlice, "AvA")["id"].(string)
		wantErr(t, e.do(qaAlice, "PATCH", "/profiles/"+id, jb(map[string]any{"ownerPin": "0420", "avatar": "bad avatar"}), ""), 400, "invalid_avatar")
		if e.profileByName(qaAlice, "AvA")["avatar"] != "a" {
			t.Errorf("invalid avatar edit altered the stored avatar")
		}
		r := e.do(qaAlice, "PATCH", "/profiles/"+id, jb(map[string]any{"ownerPin": "0420", "avatar": nil}), "")
		wantOK(t, r, 200)
		if v, ok := r.js["avatar"]; ok && v != nil && v != "" {
			t.Errorf("avatar null should clear it, response has %v", v)
		}
	})
}

func TestFR203_NameAgeLevelAndPinValidation(t *testing.T) {
	e := newQAEnv(t)
	e.setOwnerPin(qaAlice, "0420")
	post := func(over map[string]any) qaResp {
		body := map[string]any{"ownerPin": "0420", "name": "Probe", "maxAgeLevel": 2}
		for k, v := range over {
			if v == "<<delete>>" {
				delete(body, k)
			} else {
				body[k] = v
			}
		}
		return e.do(qaAlice, "POST", "/profiles", jb(body), "")
	}
	rows := func() int { return e.profileRowCount(qaAlice.id) }

	// invalid_age_level: not an integer 1-4. 0 / 5 are the boundaries just outside.
	for _, lv := range []any{0, 5, -1, 100, 2.5, "2", "x", nil, true, []int{2}, "<<delete>>"} {
		wantErr(t, post(map[string]any{"maxAgeLevel": lv}), 400, "invalid_age_level")
	}
	if rows() != 1 {
		t.Fatalf("invalid age level created a profile (%d rows)", rows())
	}
	for lv := 1; lv <= 4; lv++ {
		r := post(map[string]any{"maxAgeLevel": lv, "name": "L" + string(rune('0'+lv))})
		if lv == 4 && r.code == 409 { // account limit reached with the 4th non-owner? owner+L1+L2+L3 = 4
			wantErr(t, r, 409, "profile_limit_reached")
			continue
		}
		wantOK(t, r, 201)
		if r.num("maxAgeLevel") != lv {
			t.Errorf("level %d stored as %d", lv, r.num("maxAgeLevel"))
		}
	}

	// invalid_age_level also on edit.
	l1 := e.profileByName(qaAlice, "L1")["id"].(string)
	for _, lv := range []any{0, 5, "3", 1.5, nil} {
		wantErr(t, e.do(qaAlice, "PATCH", "/profiles/"+l1, jb(map[string]any{"ownerPin": "0420", "maxAgeLevel": lv}), ""), 400, "invalid_age_level")
	}
	if e.profileByName(qaAlice, "L1")["maxAgeLevel"] != float64(1) {
		t.Errorf("failed edit changed the level")
	}

	// invalid_profile_name: empty / whitespace only / 21 chars; 20 ok.
	e2 := newQAEnv(t)
	e2.setOwnerPin(qaAlice, "0420")
	name := func(n any) qaResp {
		return e2.do(qaAlice, "POST", "/profiles", jb(map[string]any{"ownerPin": "0420", "name": n, "maxAgeLevel": 2}), "")
	}
	for _, n := range []any{"", "   ", "\t\n", strings.Repeat("a", 21), strings.Repeat("é", 21), "  " + strings.Repeat("a", 21) + "  ", nil, 7} {
		wantErr(t, name(n), 400, "invalid_profile_name")
	}
	if e2.profileRowCount(qaAlice.id) != 1 {
		t.Errorf("invalid name created a profile")
	}
	r := name(strings.Repeat("a", 20))
	wantOK(t, r, 201)
	r = name("  " + strings.Repeat("b", 20) + "  ") // 20 after trimming
	wantOK(t, r, 201)
	if r.str("name") != strings.Repeat("b", 20) {
		t.Errorf("name must be stored trimmed, got %q", r.str("name"))
	}
	wantOK(t, name(strings.Repeat("é", 20)), 201) // 20 characters, 40 bytes: the limit is characters (FR-203)
	wantErr(t, name("x"), 409, "profile_limit_reached")

	// invalid_pin_format: exactly 4 ASCII digits, on create, edit and verify.
	e3 := newQAEnv(t)
	owner := e3.setOwnerPin(qaAlice, "0420")
	badPins := []any{"", "1", "123", "12345", "abcd", "12a4", "12 4", " 123", "1234 ", "١٢٣٤", "１２３４", "+123", "-123", "1.23", "0x12", 1234, 420, true, []int{1, 2, 3, 4}}
	for _, p := range badPins {
		wantErr(t, e3.do(qaAlice, "POST", "/profiles", jb(map[string]any{"ownerPin": "0420", "name": "P", "maxAgeLevel": 2, "pin": p}), ""), 400, "invalid_pin_format")
	}
	if e3.profileRowCount(qaAlice.id) != 1 {
		t.Errorf("invalid pin created a profile")
	}
	kid := e3.mustCreate(qaAlice, "0420", "Kid", 2, map[string]any{"pin": "0001"})
	for _, p := range badPins {
		wantErr(t, e3.do(qaAlice, "PATCH", "/profiles/"+kid, jb(map[string]any{"ownerPin": "0420", "pin": p}), ""), 400, "invalid_pin_format")
		wantErr(t, e3.do(qaAlice, "POST", "/profiles/"+kid+"/pin/verify", jb(map[string]any{"pin": p}), ""), 400, "invalid_pin_format")
	}
	// the kid's PIN is still 0001 after all those failed edits, and the bad-format verifies
	// did not consume attempts (no lockout appeared).
	wantOK(t, e3.do(qaAlice, "POST", "/profiles/"+kid+"/pin/verify", jb(map[string]any{"pin": "0001"}), ""), 200)
	// Valid boundary PINs: all zeros and all nines.
	for _, p := range []string{"0000", "9999", "0420"} {
		wantOK(t, e3.do(qaAlice, "PATCH", "/profiles/"+kid, jb(map[string]any{"ownerPin": "0420", "pin": p}), ""), 200)
		wantOK(t, e3.do(qaAlice, "POST", "/profiles/"+kid+"/pin/verify", jb(map[string]any{"pin": p}), ""), 200)
	}
	_ = owner
}

// FR-203: name unique within the account regardless of case; other accounts may reuse it.
func TestFR203_DuplicateNameCaseInsensitive(t *testing.T) {
	e := newQAEnv(t)
	e.setOwnerPin(qaAlice, "0420")
	e.setOwnerPin(qaBob, "1357")
	maya := e.mustCreate(qaAlice, "0420", "Maya", 2, nil)
	for _, n := range []string{"Maya", "maya", "MAYA", " mAyA ", "alice", "ALICE"} { // "alice" is the owner's default name
		wantErr(t, e.create(qaAlice, "0420", n, 2, nil), 409, "duplicate_profile_name")
	}
	if e.profileRowCount(qaAlice.id) != 2 {
		t.Errorf("duplicate create inserted a row")
	}
	// Another account may use the same name.
	wantOK(t, e.create(qaBob, "1357", "Maya", 2, nil), 201)

	// Rename onto an existing name collides; renaming to a case variant of ITS OWN name is fine.
	theo := e.mustCreate(qaAlice, "0420", "Theo", 3, nil)
	wantErr(t, e.do(qaAlice, "PATCH", "/profiles/"+theo, jb(map[string]any{"ownerPin": "0420", "name": "mAYA"}), ""), 409, "duplicate_profile_name")
	if e.profileByName(qaAlice, "Theo") == nil {
		t.Errorf("failed rename lost the original name")
	}
	r := e.do(qaAlice, "PATCH", "/profiles/"+maya, jb(map[string]any{"ownerPin": "0420", "name": "MAYA"}), "")
	wantOK(t, r, 200)
	if r.str("name") != "MAYA" {
		t.Errorf("self case-rename: %s", r.raw)
	}
}

// GET /profiles/age-levels equals the ProfilesAPI.md table exactly (literal copy).
func TestAgeLevelsEndpointMatchesAPIDocExactly(t *testing.T) {
	e := newQAEnv(t)
	r := e.do(qaAlice, "GET", "/profiles/age-levels", "", "")
	wantOK(t, r, 200)
	const doc = `{
  "unratedLevel": 4,
  "levels": [
    { "level": 1, "key": "littleKids", "label": "Little Kids", "movie": ["G"], "tv": ["TV-Y", "TV-G"] },
    { "level": 2, "key": "olderKids", "label": "Older Kids", "movie": ["PG"], "tv": ["TV-Y7", "TV-Y7-FV", "TV-PG"] },
    { "level": 3, "key": "teens", "label": "Teens", "movie": ["PG-13"], "tv": ["TV-14"] },
    { "level": 4, "key": "adult", "label": "Adult", "movie": ["R", "NC-17"], "tv": ["TV-MA"] }
  ]
}`
	var want, got any
	if err := json.Unmarshal([]byte(doc), &want); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(r.raw, &got); err != nil {
		t.Fatalf("response not JSON: %s", r.raw)
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("age-levels response differs from ProfilesAPI.md:\n got %s\nwant %v", r.raw, want)
	}
}

// API doc "Profile object": exact key set; no pin material, ever; GET /profiles also lists
// maxProfiles 4 and the caller's active profile.
func TestProfileObjectShapeAndListEnvelope(t *testing.T) {
	e := newQAEnv(t)
	owner := e.setOwnerPin(qaAlice, "0420")
	kid := e.mustCreate(qaAlice, "0420", "Maya", 2, map[string]any{"avatar": "fox"})
	r := e.do(qaAlice, "GET", "/profiles", "", "")
	wantOK(t, r, 200)
	if r.num("maxProfiles") != 4 {
		t.Errorf("maxProfiles = %v, want 4", r.js["maxProfiles"])
	}
	ps, _ := r.js["profiles"].([]any)
	if len(ps) != 2 {
		t.Fatalf("want 2 profiles, got %s", r.raw)
	}
	wantKeys := []string{"avatar", "createdAt", "hasPin", "id", "isOwner", "kids", "maxAgeLevel", "name"}
	for _, p := range ps {
		m := p.(map[string]any)
		var keys []string
		for k := range m {
			keys = append(keys, k)
		}
		sortStrings(keys)
		if !reflect.DeepEqual(keys, wantKeys) {
			t.Errorf("profile object keys = %v, want %v", keys, wantKeys)
		}
	}
	first, second := ps[0].(map[string]any), ps[1].(map[string]any)
	if first["id"] != owner || first["isOwner"] != true || first["hasPin"] != true || first["maxAgeLevel"] != float64(4) {
		t.Errorf("owner entry wrong / not first (oldest first): %v", first)
	}
	if second["id"] != kid || second["isOwner"] != false || second["hasPin"] != false || second["name"] != "Maya" || second["avatar"] != "fox" || second["maxAgeLevel"] != float64(2) {
		t.Errorf("kid entry wrong: %v", second)
	}
	if ca, _ := second["createdAt"].(string); len(ca) != len("2026-10-17T19:00:00Z") || !strings.HasSuffix(ca, "Z") {
		t.Errorf("createdAt not ISO-8601 UTC: %q", ca)
	}
	// Another account's listing never contains these.
	other := e.do(qaBob, "GET", "/profiles", "", "")
	if strings.Contains(string(other.raw), owner) || strings.Contains(string(other.raw), kid) {
		t.Errorf("bob's /profiles leaked alice's ids: %s", other.raw)
	}
}

func sortStrings(s []string) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j] < s[j-1]; j-- {
			s[j], s[j-1] = s[j-1], s[j]
		}
	}
}

// FR-205 (coordinator requirement): an account with ONLY its owner profile behaves exactly as
// before profiles. No header and the owner header both resolve to the owner; progress
// written with no header reads back with no header and with the owner header; watchlist
// likewise; nothing is filtered (an unrated item and an R item both list).
func TestFR205_OwnerOnlyAccountBehavesAsBeforeProfiles(t *testing.T) {
	e := newQAEnv(t)
	owner := e.ownerID(qaAlice)
	e.seedItem("it_unrated", "Drama", nil)
	e.seedItem("it_r", "Horror", sp("R"))
	e.seedItem("it_g", "Family", sp("G"))
	e.seedItem("it_x", "Drama", sp("X")) // unknown string

	for _, h := range []string{"", owner} {
		r := e.do(qaAlice, "GET", "/libraries", "", h)
		if got := r.hdr.Get("X-DSVideo-Profile"); got != owner {
			t.Errorf("header %q resolved to %q, want owner %q", h, got, owner)
		}
	}

	// listing: nothing filtered (NULL-rated, R, unknown and G all present, total counts all four)
	for _, h := range []string{"", owner} {
		r := e.do(qaAlice, "GET", "/items?libraryId=lib1", "", h)
		wantOK(t, r, 200)
		ids := map[string]bool{}
		items, _ := r.js["items"].([]any)
		for _, it := range items {
			ids[it.(map[string]any)["id"].(string)] = true
		}
		for _, want := range []string{"it_unrated", "it_r", "it_g", "it_x"} {
			if !ids[want] {
				t.Errorf("header %q: /items hides %s on an owner-only account: %s", h, want, r.raw)
			}
		}
		if len(items) != 4 {
			t.Errorf("header %q: /items returned %d items, want 4", h, len(items))
		}
	}
	for _, id := range []string{"it_unrated", "it_r"} {
		if r := e.do(qaAlice, "GET", "/items/"+id, "", ""); r.code != 200 {
			t.Errorf("GET /items/%s = %d %s, want 200 for an owner-only account", id, r.code, r.raw)
		}
	}

	// progress: written with NO header, read with none and with the owner header.
	wantOK(t, e.do(qaAlice, "POST", "/items/it_r/progress", jb(map[string]any{"positionSeconds": 321, "durationSeconds": 5000}), ""), 200)
	wantOK(t, e.do(qaAlice, "POST", "/items/it_unrated/progress", jb(map[string]any{"positionSeconds": 12, "durationSeconds": 600}), owner), 200)
	for _, h := range []string{"", owner} {
		r := e.do(qaAlice, "GET", "/progress/all", "", h)
		prog, _ := r.js["progress"].(map[string]any)
		if len(prog) != 2 {
			t.Errorf("header %q: /progress/all has %d entries, want 2: %s", h, len(prog), r.raw)
		}
		if m, _ := prog["it_r"].(map[string]any); m == nil || m["positionSeconds"] != float64(321) || m["durationSeconds"] != float64(5000) {
			t.Errorf("header %q: it_r progress = %v, want 321/5000", h, prog["it_r"])
		}
		if m, _ := prog["it_unrated"].(map[string]any); m == nil || m["positionSeconds"] != float64(12) {
			t.Errorf("header %q: it_unrated progress = %v, want 12", h, prog["it_unrated"])
		}
		b := e.do(qaAlice, "GET", "/progress?ids=it_r,it_unrated,it_g", "", h)
		if bp, _ := b.js["progress"].(map[string]any); len(bp) != 2 || bp["it_g"] != nil {
			t.Errorf("header %q: /progress batch = %s", h, b.raw)
		}
		jw := e.do(qaAlice, "GET", "/items?filter=justWatched", "", h)
		if jw.num("total") != 2 {
			t.Errorf("header %q: justWatched total = %v, want 2: %s", h, jw.js["total"], jw.raw)
		}
	}

	// watchlist: R and unrated can be added by an owner-only account, via either header.
	wantOK(t, e.do(qaAlice, "POST", "/watchlist/it_r", "", ""), 200)
	wantOK(t, e.do(qaAlice, "POST", "/watchlist/it_unrated", "", owner), 200)
	for _, h := range []string{"", owner} {
		r := e.do(qaAlice, "GET", "/watchlist", "", h)
		items, _ := r.js["items"].([]any)
		got := map[string]bool{}
		for _, it := range items {
			got[it.(map[string]any)["id"].(string)] = true
		}
		if len(items) != 2 || !got["it_r"] || !got["it_unrated"] {
			t.Errorf("header %q: watchlist = %s, want it_r + it_unrated", h, r.raw)
		}
		c := e.do(qaAlice, "GET", "/watchlist/it_r", "", h)
		if c.js["inWatchlist"] != true {
			t.Errorf("header %q: /watchlist/it_r inWatchlist = %v", h, c.js["inWatchlist"])
		}
	}
	// removal through the other header is the same list
	r := e.do(qaAlice, "DELETE", "/watchlist/it_r", "", owner)
	wantOK(t, r, 200)
	if c := e.do(qaAlice, "GET", "/watchlist/it_r", "", ""); c.js["inWatchlist"] != false {
		t.Errorf("remove via owner header did not remove for no-header reads: %s", c.raw)
	}
	if e.count(`SELECT COUNT(*) FROM profiles WHERE user_id=?`, qaAlice.id) != 1 {
		t.Errorf("owner-only usage created extra profiles")
	}
}
