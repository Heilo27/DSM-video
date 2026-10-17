package main

import (
	"testing"

	"dsvideo/backend/internal/rating"
)

// TASK-921 / TASK-922: the server is the one home of "is this a kids' profile" and of "which
// ceiling is unrestricted"; clients read both off GET /profiles instead of holding literals.

// offersKidsCollections reports whether a profile at level gets the kids-audience collections
// (FR-274), the server behaviour the wire "kids" flag must agree with.
func offersKidsCollections(level int) bool {
	for _, d := range collectionsFor(viewer{MaxAgeLevel: level}) {
		if d.Audience == collectionAudienceKids {
			return true
		}
	}
	return false
}

// tierLevel returns the ladder level whose key is key (FR-270 names tiers, not numbers).
func tierLevel(t *testing.T, key string) int {
	t.Helper()
	for _, tr := range rating.Tiers() {
		if tr.Key == key {
			return tr.Level
		}
	}
	t.Fatalf("no tier %q in the ladder", key)
	return 0
}

func TestTASK921_KidsFlagOnEveryProfileObjectAgreesWithCollectionsOffered(t *testing.T) {
	e := newQAEnv(t)
	e.setOwnerPin(qaAlice, "0420")
	littleKids, olderKids, teens := tierLevel(t, "littleKids"), tierLevel(t, "olderKids"), tierLevel(t, "teens")

	created := map[string]int{}
	for name, lvl := range map[string]int{"Lil": littleKids, "Maya": olderKids, "Theo": teens} {
		r := e.create(qaAlice, "0420", name, lvl, nil)
		wantOK(t, r, 201)
		kids, present := r.js["kids"].(bool)
		if !present {
			t.Fatalf("POST /profiles response has no boolean kids: %s", r.raw)
		}
		if kids != offersKidsCollections(lvl) {
			t.Errorf("POST %s (level %d): kids=%v but kids collections offered=%v", name, lvl, kids, offersKidsCollections(lvl))
		}
		created[r.str("id")] = lvl
	}

	// FR-270: Older Kids is the highest kids' ceiling; Teens and Adult are not kids.
	want := map[int]bool{littleKids: true, olderKids: true, teens: false, rating.MaxLevel: false}
	list := e.do(qaAlice, "GET", "/profiles", "", "")
	wantOK(t, list, 200)
	ps, _ := list.js["profiles"].([]any)
	if len(ps) != 4 {
		t.Fatalf("want owner + 3 profiles, got %s", list.raw)
	}
	for _, p := range ps {
		m := p.(map[string]any)
		lvl := int(m["maxAgeLevel"].(float64))
		kids, present := m["kids"].(bool)
		if !present {
			t.Fatalf("GET /profiles entry has no boolean kids: %v", m)
		}
		if kids != want[lvl] {
			t.Errorf("profile %v (level %d): kids=%v, FR-270 says %v", m["name"], lvl, kids, want[lvl])
		}
		if kids != offersKidsCollections(lvl) {
			t.Errorf("profile %v (level %d): wire kids=%v disagrees with collections offered=%v", m["name"], lvl, kids, offersKidsCollections(lvl))
		}
	}

	// PATCH answers with the recomputed flag: Maya promoted to Teens stops being a kid.
	maya := e.profileByName(qaAlice, "Maya")["id"].(string)
	r := e.do(qaAlice, "PATCH", "/profiles/"+maya, jb(map[string]any{"ownerPin": "0420", "maxAgeLevel": teens}), "")
	wantOK(t, r, 200)
	if kids, present := r.js["kids"].(bool); !present || kids {
		t.Errorf("PATCH to Teens: kids=%v present=%v, want false: %s", kids, present, r.raw)
	}
	r = e.do(qaAlice, "PATCH", "/profiles/"+maya, jb(map[string]any{"ownerPin": "0420", "maxAgeLevel": littleKids}), "")
	wantOK(t, r, 200)
	if kids, _ := r.js["kids"].(bool); !kids {
		t.Errorf("PATCH back to Little Kids: kids=false, want true: %s", r.raw)
	}
}

func TestTASK921_KidsFlagIsNotAcceptedOnInput(t *testing.T) {
	e := newQAEnv(t)
	e.setOwnerPin(qaAlice, "0420")
	teens := tierLevel(t, "teens")
	// A client asserting kids:true for a Teens ceiling must not change what the server computes.
	r := e.create(qaAlice, "0420", "Theo", teens, map[string]any{"kids": true})
	if r.code == 201 {
		if kids, _ := r.js["kids"].(bool); kids {
			t.Errorf("POST with kids:true at Teens stored/echoed kids=true: %s", r.raw)
		}
	}
	if p := e.profileByName(qaAlice, "Theo"); p != nil && p["kids"] == true {
		t.Errorf("listing shows Theo (Teens) as kids after a kids:true create: %v", p)
	}
}

func TestTASK922_ProfilesListCarriesUnrestrictedLevelThatAgreesWithServerFiltering(t *testing.T) {
	e := newQAEnv(t)
	r := e.do(qaAlice, "GET", "/profiles", "", "")
	wantOK(t, r, 200)
	raw, present := r.js["unrestrictedLevel"].(float64)
	if !present {
		t.Fatalf("GET /profiles has no numeric top-level unrestrictedLevel: %s", r.raw)
	}
	unrestricted := int(raw)

	top := 0
	for _, tr := range rating.Tiers() {
		if tr.Level > top {
			top = tr.Level
		}
	}
	if unrestricted != top {
		t.Errorf("unrestrictedLevel = %d, want the top of the ladder %d", unrestricted, top)
	}
	// The client's rule (restricted when maxAgeLevel < unrestrictedLevel) must give the
	// server's answer at every ceiling a profile may hold.
	for lvl := rating.MinLevel; lvl <= rating.MaxLevel; lvl++ {
		if client, server := lvl < unrestricted, rating.Restricted(lvl); client != server {
			t.Errorf("level %d: client restricted=%v, server restricted=%v", lvl, client, server)
		}
	}
	// The owner profile (unrestricted by FR-205) holds exactly that level.
	if own := e.profiles(qaAlice); len(own) != 1 || int(own[0]["maxAgeLevel"].(float64)) != unrestricted {
		t.Errorf("owner profile level != unrestrictedLevel %d: %v", unrestricted, own)
	}
}
