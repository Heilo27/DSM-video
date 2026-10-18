package main

// TASK-932 SEC-7 / FR-215: PIN lockout state survives a server restart. "Restart" here is
// a brand-new Server (and so a brand-new limiter) over the same database file, which is
// all a package restart leaves behind.

import (
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
)

// restarted returns a fresh server over e's database, its PIN clock set to clk.
func (e *qaEnv) restarted(clk *qaClock) *qaEnv {
	e.t.Helper()
	s := &Server{db: e.db, cfg: e.s.cfg}
	s.justAdded = newJustAddedCache()
	r := chi.NewRouter()
	registerAPIRoutes(r, s)
	setPinClock(s, clk.now)
	return &qaEnv{t: e.t, s: s, db: e.db, dbPath: e.dbPath, h: r}
}

func (e *qaEnv) pinRows() int {
	return e.count(`SELECT COUNT(*) FROM profile_pin_lockouts`)
}

// A locked profile stays locked across a restart, the correct PIN still refused, with the
// remaining wait carried over. After the wait, the correct PIN succeeds and clears the
// stored state, so a later restart starts from a clean budget.
// Red if lockout lives only in memory, the stored deadline is lost or shifted, or a
// success leaves the old count on disk.
func TestSEC7_LockoutSurvivesRestart_SuccessClearsIt(t *testing.T) {
	e := newQAEnv(t)
	clk := newQAClock(e)
	e.setOwnerPin(qaAlice, "0420")
	kid := e.mustCreate(qaAlice, "0420", "Kid", 1, map[string]any{"pin": "1111"})

	for i := 0; i < 5; i++ {
		wantErr(t, e.verify(qaAlice, kid, "9999"), 403, "pin_incorrect")
	}
	clk.advance(100 * time.Second)

	e2 := e.restarted(clk)
	wantLocked(t, e2.verify(qaAlice, kid, "1111"), 199, 200)

	clk.advance(201 * time.Second)
	wantOK(t, e2.verify(qaAlice, kid, "1111"), 200)
	if n := e2.pinRows(); n != 0 {
		t.Errorf("profile_pin_lockouts rows after a success = %d, want 0", n)
	}

	e3 := e2.restarted(clk)
	r := e3.verify(qaAlice, kid, "9999")
	wantErr(t, r, 403, "pin_incorrect")
	if got := r.num("attemptsRemaining"); got != 4 {
		t.Errorf("after success + restart, attemptsRemaining = %d, want 4", got)
	}
}

// Failures short of a lockout count across a restart: 3 wrong, restart, the 4th leaves 1.
// Red if a restart hands back a fresh 5-guess budget.
func TestSEC7_PartialFailuresSurviveRestart(t *testing.T) {
	e := newQAEnv(t)
	clk := newQAClock(e)
	e.setOwnerPin(qaAlice, "0420")
	kid := e.mustCreate(qaAlice, "0420", "Kid", 1, map[string]any{"pin": "1111"})

	for i := 0; i < 3; i++ {
		wantErr(t, e.verify(qaAlice, kid, "9999"), 403, "pin_incorrect")
	}
	r := e.restarted(clk).verify(qaAlice, kid, "9999")
	wantErr(t, r, 403, "pin_incorrect")
	if got := r.num("attemptsRemaining"); got != 1 {
		t.Errorf("attemptsRemaining after restart = %d, want 1", got)
	}
}

// Escalation survives a restart: the second lockout after a restart is 10 minutes, not 5.
// Red if the lockout count is not persisted.
func TestSEC7_EscalationSurvivesRestart(t *testing.T) {
	e := newQAEnv(t)
	clk := newQAClock(e)
	e.setOwnerPin(qaAlice, "0420")
	kid := e.mustCreate(qaAlice, "0420", "Kid", 1, map[string]any{"pin": "1111"})

	for i := 0; i < 5; i++ {
		e.verify(qaAlice, kid, "9999")
	}
	clk.advance(301 * time.Second)

	e2 := e.restarted(clk)
	for i := 0; i < 5; i++ {
		wantErr(t, e2.verify(qaAlice, kid, "9999"), 403, "pin_incorrect")
	}
	wantLocked(t, e2.restarted(clk).verify(qaAlice, kid, "1111"), 595, 600)
}

// Setting a profile's PIN (limiter reset) clears its stored state too, so a restart does
// not resurrect the old lockout.
// Red if reset only forgets the in-memory entry.
func TestSEC7_ResetClearsStoredState(t *testing.T) {
	e := newQAEnv(t)
	clk := newQAClock(e)
	e.setOwnerPin(qaAlice, "0420")
	kid := e.mustCreate(qaAlice, "0420", "Kid", 1, map[string]any{"pin": "1111"})

	for i := 0; i < 5; i++ {
		e.verify(qaAlice, kid, "9999")
	}
	if n := e.pinRows(); n != 1 {
		t.Fatalf("precondition: profile_pin_lockouts rows = %d, want 1", n)
	}
	e.s.pinLimiter().reset(kid)
	if n := e.pinRows(); n != 0 {
		t.Errorf("rows after reset = %d, want 0", n)
	}
	wantOK(t, e.restarted(clk).verify(qaAlice, kid, "1111"), 200)
}
