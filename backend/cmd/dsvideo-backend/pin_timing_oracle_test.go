package main

// TASK-970 / OC-2064 (FR-214): the PIN hash is slow enough to resist guessing but a verify
// must still answer inside one second on the slowest supported NAS CPU. The same test runs on
// the NAS itself (go test -c, copied over; see the TASK-970 note), where it is the OC-2064
// measurement; on a dev machine it is the regression guard for the iteration count.

import (
	"testing"
	"time"
)

// OC-2064. given: a profile with a PIN. when: 10 POST /pin/verify with the correct PIN are
// timed one by one. then: every one answers 200 {ok:true} in under 1 second. A wrong PIN is
// verified first so the timed path is known to do the real hash, not a shortcut. Red if
// pinHashIterations is raised until one verify takes a second (e.g. 20_000_000).
func TestOC2064_TenPinVerifiesEachCompleteUnderOneSecond(t *testing.T) {
	e := newQAEnv(t)
	e.setOwnerPin(qaAlice, "0420")
	kid := e.mustCreate(qaAlice, "0420", "Kid", 1, map[string]any{"pin": "1111"})

	wantErr(t, e.verify(qaAlice, kid, "9999"), 403, "pin_incorrect")

	for i := 1; i <= 10; i++ {
		start := time.Now()
		r := e.verify(qaAlice, kid, "1111")
		took := time.Since(start)
		wantOK(t, r, 200)
		if r.js["ok"] != true {
			t.Errorf("verify %d: body %s, want {\"ok\":true}", i, r.raw)
		}
		if took >= time.Second {
			t.Errorf("verify %d took %v, want under 1s (FR-214)", i, took)
		}
		t.Logf("verify %d: %v", i, took)
	}
}
