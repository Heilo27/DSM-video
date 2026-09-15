package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/go-chi/chi/v5"
)

// TASK-905 — /shows and /tv/shows were two implementations of one concept emitting two
// different shapes: /shows gave showName + folderName and no id at all, /tv/shows gave
// id + title. Every change to show identity had to be made twice, and TASK-900 is on
// record as having been applied to only one of them.
//
// These tests pin the collapsed contract. They assert the field names literally rather
// than comparing the two handlers' output to each other — two handlers that agree on the
// wrong shape would satisfy a symmetry check, and the point here is that `id` and `title`
// specifically are what both planes speak.

// TestShowsListEmitsCanonicalShape guards the legacy /shows list route. It must speak the
// /tv/shows shape, and must NOT reintroduce the showName/folderName pair.
func TestShowsListEmitsCanonicalShape(t *testing.T) {
	s := singleConnServer(t, 3)

	rec := httptest.NewRecorder()
	s.handleShowsList(rec, authedReq(http.MethodGet, "/shows", "u1"))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}

	var payload struct {
		Shows []map[string]any `json:"shows"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatalf("decode body: %v (body: %s)", err, rec.Body.String())
	}
	if len(payload.Shows) != 1 {
		t.Fatalf("got %d shows, want 1", len(payload.Shows))
	}
	show := payload.Shows[0]

	if _, ok := show["id"]; !ok {
		t.Error("/shows emitted no `id` — the legacy route must carry the same identity /tv/shows does")
	}
	if _, ok := show["title"]; !ok {
		t.Error("/shows emitted no `title`")
	}
	if _, ok := show["showName"]; ok {
		t.Error("/shows re-emitted `showName`; the canonical field is `title` (TASK-905)")
	}
	if _, ok := show["folderName"]; ok {
		t.Error("/shows re-emitted `folderName`; the canonical field is `id` (TASK-905)")
	}

	if got := show["title"]; got != "Daredevil" {
		t.Errorf("title = %v, want \"Daredevil\"", got)
	}
	if got := show["id"]; got != "Daredevil" {
		t.Errorf("id = %v, want \"Daredevil\" (the folder name)", got)
	}
}

// TestShowsListMatchesTVShowsList is the anti-drift assertion: the legacy route is an
// adapter, so byte-for-byte it must be the canonical route's answer. If someone ever
// reintroduces a second grouping implementation behind /shows, the two diverge here.
func TestShowsListMatchesTVShowsList(t *testing.T) {
	s := singleConnServer(t, 4)

	legacy := httptest.NewRecorder()
	s.handleShowsList(legacy, authedReq(http.MethodGet, "/shows", "u1"))

	canonical := httptest.NewRecorder()
	s.handleTVShowsList(canonical, authedReq(http.MethodGet, "/tv/shows", "u1"))

	if legacy.Body.String() != canonical.Body.String() {
		t.Errorf("/shows and /tv/shows disagree — the show planes have diverged again (TASK-905).\n/shows:    %s\n/tv/shows: %s",
			legacy.Body.String(), canonical.Body.String())
	}
}

// TestShowDetailEmitsCanonicalIdentity guards the detail route. It used to emit `showName`
// and no id, so a caller could not carry an identity from a list into a detail without
// knowing which of the two planes had produced it.
func TestShowDetailEmitsCanonicalIdentity(t *testing.T) {
	s := singleConnServer(t, 3)

	req := authedReq(http.MethodGet, "/shows/Daredevil", "u1")
	rctx := chi.NewRouteContext()
	rctx.URLParams.Add("showName", "Daredevil")
	req = req.WithContext(context.WithValue(req.Context(), chi.RouteCtxKey, rctx))

	rec := httptest.NewRecorder()
	s.handleShowDetail(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}

	var payload map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatalf("decode body: %v (body: %s)", err, rec.Body.String())
	}

	if _, ok := payload["showName"]; ok {
		t.Error("/shows/{showName} re-emitted `showName`; the canonical field is `title` (TASK-905)")
	}
	if got := payload["id"]; got != "Daredevil" {
		t.Errorf("id = %v, want \"Daredevil\" — the detail must echo the id the list emits", got)
	}
	if got := payload["title"]; got != "Daredevil" {
		t.Errorf("title = %v, want \"Daredevil\"", got)
	}

	// The id must be the value a caller can feed straight back in — i.e. the same id the
	// list plane hands out for this show.
	listRec := httptest.NewRecorder()
	s.handleTVShowsList(listRec, authedReq(http.MethodGet, "/tv/shows", "u1"))
	var list struct {
		Shows []struct {
			ID string `json:"id"`
		} `json:"shows"`
	}
	if err := json.Unmarshal(listRec.Body.Bytes(), &list); err != nil {
		t.Fatalf("decode list body: %v", err)
	}
	if len(list.Shows) != 1 {
		t.Fatalf("got %d shows from the list plane, want 1", len(list.Shows))
	}
	if list.Shows[0].ID != payload["id"] {
		t.Errorf("list id %q != detail id %v — an id from the list is not usable against the detail",
			list.Shows[0].ID, payload["id"])
	}
}
