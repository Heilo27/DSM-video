package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
	_ "modernc.org/sqlite"
)

// TASK-904 — querying inside an open cursor exhausts the connection pool.
//
// Three handlers called s.getProgress once per row WHILE their `rows` cursor was still open.
// A cursor holds a pool connection for as long as it is being drained, so each per-row query
// needs a SECOND connection. Under concurrency every connection ends up held by a cursor whose
// goroutine is blocked waiting for a connection that only frees when a cursor closes — and none
// can. handleTVShowEpisodes carries a comment describing this exact outage; it was fixed there
// and the same shape survived in handleShowDetail (main.go) and webAPITVShowEpisodeList
// (webapi.go).
//
// HOW THIS TEST PROVES IT, rather than describing it: the pool is pinned to ONE connection.
// With the defective shape the handler cannot make progress — the cursor holds the only
// connection and the per-row query waits forever for a second one. With the fix, the cursor is
// drained and closed before any progress query runs, so one connection is sufficient.
//
// A deadlock test must never be able to hang the suite, so the handler runs in a goroutine
// behind a timeout: the assertion is "completes within the budget", and a regression fails
// loudly instead of wedging CI.

const cursorPoolSchema = `
CREATE TABLE items(
  id TEXT PRIMARY KEY, library_id TEXT, type TEXT, title TEXT, episode_title TEXT,
  year INT, path TEXT, duration_seconds INT, added_at TEXT, updated_at TEXT,
  rating REAL, poster_path TEXT, backdrop_path TEXT, overview TEXT, genres TEXT,
  director TEXT, show_name TEXT, season_number INT, episode_number INT,
  change_seq INT, show_folder_id TEXT, tmdb_id INT);
CREATE TABLE progress(
  item_id TEXT, user_id TEXT, position_seconds INT, duration_seconds INT,
  updated_at TEXT, write_seq INT, PRIMARY KEY(item_id, user_id));
`

// singleConnServer builds a server whose pool holds exactly ONE connection, seeded with
// `episodes` episodes of one show, each carrying a progress row.
func singleConnServer(t *testing.T, episodes int) *Server {
	t.Helper()
	db, err := sql.Open("sqlite", "file:cursorpool?mode=memory&cache=shared")
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { db.Close() })

	// The whole point of the test. With more than one connection available the defective
	// shape merely gets slow instead of stuck, and the test would pass against the bug.
	db.SetMaxOpenConns(1)

	if _, err := db.Exec(cursorPoolSchema); err != nil {
		t.Fatalf("schema: %v", err)
	}
	for i := 1; i <= episodes; i++ {
		id := "ep" + string(rune('A'+i-1))
		if _, err := db.Exec(
			`INSERT INTO items(id, library_id, type, title, episode_title, path,
			                   duration_seconds, season_number, episode_number, show_name)
			 VALUES(?, 'lib_tv', 'episode', ?, ?, ?, 3600, 1, ?, 'Daredevil')`,
			id, "Daredevil", "Into the Ring", "/tv/Daredevil/S01E0"+string(rune('0'+i))+".mkv", i,
		); err != nil {
			t.Fatalf("insert item: %v", err)
		}
		if _, err := db.Exec(
			`INSERT INTO progress(item_id, user_id, position_seconds, duration_seconds, updated_at)
			 VALUES(?, 'u1', 1800, 3600, '2026-01-01T00:00:00Z')`, id,
		); err != nil {
			t.Fatalf("insert progress: %v", err)
		}
	}
	return &Server{cfg: Config{TVPath: testTVRoot}, db: db}
}

func TestShowDetailCompletesOnASingleConnection(t *testing.T) {
	s := singleConnServer(t, 6)

	// Reuses the existing helper so the auth-context shape stays in one place.
	req := authedReq(http.MethodGet, "/shows/Daredevil", "u1")
	rctx := chi.NewRouteContext()
	rctx.URLParams.Add("showName", "Daredevil")
	req = req.WithContext(context.WithValue(req.Context(), chi.RouteCtxKey, rctx))
	rec := httptest.NewRecorder()

	done := make(chan struct{})
	go func() {
		defer close(done)
		s.handleShowDetail(rec, req)
	}()

	select {
	case <-done:
		// Completed — the cursor was drained and closed before progress was queried.
	case <-time.After(10 * time.Second):
		t.Fatal("handleShowDetail did not complete on a single-connection pool within 10s — " +
			"a query is running inside the open rows cursor again (TASK-904). " +
			"Drain the cursor into a slice, Close() it, then use getProgressBatch.")
	}

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}

	// Episodes are nested under seasons[].episodes, not a flat key.
	var payload struct {
		Seasons []struct {
			Episodes []struct {
				ID       string         `json:"id"`
				Watched  bool           `json:"watched"`
				Progress map[string]any `json:"progress"`
			} `json:"episodes"`
		} `json:"seasons"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatalf("decode body: %v (body: %s)", err, rec.Body.String())
	}
	type respEp struct {
		ID       string
		Watched  bool
		Progress map[string]any
	}
	var all []respEp
	for _, sn := range payload.Seasons {
		for _, ep := range sn.Episodes {
			all = append(all, respEp{ID: ep.ID, Watched: ep.Watched, Progress: ep.Progress})
		}
	}

	// Completing is necessary but not sufficient: the batch must return the SAME progress the
	// per-row query did, or the fix traded a deadlock for missing data.
	if len(all) != 6 {
		t.Fatalf("episodes = %d, want 6", len(all))
	}
	for _, ep := range all {
		if ep.Progress == nil {
			t.Errorf("episode %s has no progress — the batch query dropped it", ep.ID)
			continue
		}
		// Seeded at 1800/3600 = 0.5, which is below the 0.85 watched threshold.
		if got, want := ep.Progress["positionSeconds"], float64(1800); got != want {
			t.Errorf("episode %s positionSeconds = %v, want %v", ep.ID, got, want)
		}
		if ep.Watched {
			t.Errorf("episode %s marked watched at 50%% — threshold is 0.85", ep.ID)
		}
	}
}

func TestWebAPIEpisodeListCompletesOnASingleConnection(t *testing.T) {
	s := singleConnServer(t, 5)

	req := httptest.NewRequest(http.MethodGet, "/webapi/entry.cgi?limit=50&offset=0", nil)
	rec := httptest.NewRecorder()
	session := &WebAPISession{SID: "sid-1", UserID: "u1"}

	done := make(chan struct{})
	go func() {
		defer close(done)
		s.webAPITVShowEpisodeList(rec, req, session)
	}()

	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("webAPITVShowEpisodeList did not complete on a single-connection pool within 10s — " +
			"a query is running inside the open rows cursor again (TASK-904).")
	}

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}

	var payload struct {
		Data struct {
			Episodes []struct {
				WatchStatus map[string]any `json:"watch_status"`
			} `json:"tvshow_episode"`
		} `json:"data"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatalf("decode body: %v (body: %s)", err, rec.Body.String())
	}
	if len(payload.Data.Episodes) != 5 {
		t.Fatalf("episodes = %d, want 5", len(payload.Data.Episodes))
	}
	for i, ep := range payload.Data.Episodes {
		if ep.WatchStatus == nil {
			t.Errorf("episode %d lost its watch_status — the batch query dropped it", i)
			continue
		}
		if got, want := ep.WatchStatus["time"], float64(1800); got != want {
			t.Errorf("episode %d watch_status.time = %v, want %v", i, got, want)
		}
	}
}
