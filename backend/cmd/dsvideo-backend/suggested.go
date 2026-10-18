package main

import (
	"net/http"
	"strings"
)

// broadGenres are too common to make a useful recommendation.
//
// A library's Drama bucket is routinely a third of it, so "Because you watched … Drama" is
// close to a random shuffle. Skipped when anything more specific is available; used anyway
// when nothing else is, because a broad suggestion still beats an empty rail.
//
// Mirrors AppState.suggestionGenre on the client, which applies the same rule when it has to
// fall back to the two-request path against an older server. Both lists must agree, or the
// rail's subtitle would name a different genre than the one the items were chosen from.
var broadGenres = map[string]bool{
	"Drama": true, "Comedy": true, "Action": true, "Thriller": true, "Adventure": true,
}

// pickSuggestionGenre returns the most useful genre from a comma-separated TMDb list.
func pickSuggestionGenre(csv string) string {
	var fallback string
	for _, g := range strings.Split(csv, ",") {
		g = strings.TrimSpace(g)
		if g == "" {
			continue
		}
		if fallback == "" {
			fallback = g
		}
		if !broadGenres[g] {
			return g
		}
	}
	return fallback
}

// handleSuggested returns titles sharing a genre with whatever this user watched most
// recently, for the home screen's Suggested rail.
//
// WHY THIS IS A SERVER ENDPOINT
// -----------------------------
// The client can almost do this itself — it did first — but only in two round trips: fetch
// the seed item's detail to learn its genres, then fetch a filtered page. ItemSummary
// carries no genres, so the first request exists purely to read one field. Worse, the client
// picks the seed from its OWN rails, which are built from locally-synced progress; a client
// whose sync has stalled seeds from stale data and suggests against a film watched weeks ago.
//
// Here the seed comes from the progress table directly, so it is right even when the client
// is behind, and it is one request.
//
// Excludes anything the viewer has progress on. The rail sits beneath Continue Watching and
// repeating its contents would be noise — and suggesting something already half-watched is
// not a suggestion.
func (s *Server) handleSuggested(w http.ResponseWriter, r *http.Request) {
	u := userFromCtx(r.Context())
	libraryID := strings.TrimSpace(r.URL.Query().Get("libraryId"))
	limit := clampInt(parseInt(r.URL.Query().Get("limit"), 8), 1, 30)

	empty := map[string]any{"genre": "", "items": []any{}}
	if u.ID == "" {
		writeJSON(w, http.StatusOK, empty)
		return
	}
	// Seeded from, and excluding, the viewing profile's progress (FR-230), and held to its
	// ceiling (FR-250). The ceiling is in both WHEREs, so the seed is a title the viewer can
	// see (a progress write above the ceiling is accepted, FR-231, but must not steer the
	// rail) and LIMIT counts only visible rows: the rail is never left short by filtering.
	v, ok := s.requestViewer(w, r)
	if !ok {
		return
	}
	vis, visArgs := v.andVisibleFrag("i.content_rating")

	// The seed: the most recently watched item that actually has genres. Ordering by
	// progress.updated_at is what makes this track real viewing — the same column the home
	// rails sort on, and the reason it now carries the client's watch time rather than the
	// server's receive time.
	var seedGenres string
	err := s.db.QueryRow(`
		SELECT i.genres
		FROM progress p
		JOIN items i ON i.id = p.item_id
		WHERE p.profile_id = ? AND i.genres IS NOT NULL AND i.genres != ''`+vis+`
		ORDER BY p.updated_at DESC
		LIMIT 1`, append([]any{v.ProfileID}, visArgs...)...).Scan(&seedGenres)
	if err != nil {
		// No progress at all is the ordinary first-run case, not an error: answer with an
		// empty rail rather than a status the client has to special-case.
		writeJSON(w, http.StatusOK, empty)
		return
	}

	genre := pickSuggestionGenre(seedGenres)
	if genre == "" {
		writeJSON(w, http.StatusOK, empty)
		return
	}

	// LIKE with an escaped pattern, because genres is a comma-separated column rather than a
	// join table. Matching ',Genre,' against a padded copy avoids the classic substring bug
	// where "Action" also matches "Live Action".
	where := `i.genres IS NOT NULL AND ',' || REPLACE(i.genres, ', ', ',') || ',' LIKE ? ESCAPE '\'`
	args := []any{"%," + escapeLike(genre) + ",%"}
	if libraryID != "" {
		where += " AND i.library_id = ?"
		args = append(args, libraryID)
	}
	// Never suggest something already being watched — that is Continue Watching's job.
	where += " AND i.id NOT IN (SELECT item_id FROM progress WHERE profile_id = ?)"
	args = append(args, v.ProfileID)
	where += vis
	args = append(args, visArgs...)

	// RANDOM() so the rail differs between launches instead of showing the same
	// alphabetical head forever.
	args = append(args, limit)
	rows, err := s.db.Query(`
		SELECT i.id, i.type, i.title, i.year, i.duration_seconds, i.added_at, i.rating,
		       i.poster_path, i.backdrop_path, i.show_name, i.season_number, i.episode_number,
		       i.show_folder_id, i.content_rating
		FROM items i
		WHERE `+where+`
		ORDER BY RANDOM()
		LIMIT ?`, args...)
	if err != nil {
		writeFailure(w, r, http.StatusInternalServerError, "db_error", err)
		return
	}
	defer rows.Close()

	items := make([]map[string]any, 0, limit)
	for rows.Next() {
		// No progress column: the query excludes every title the profile has progress on.
		var row itemSummaryRow
		if err := rows.Scan(&row.ID, &row.Type, &row.Title, &row.Year, &row.Duration, &row.AddedAt, &row.Rating,
			&row.PosterPath, &row.BackdropPath, &row.ShowName, &row.SeasonNumber, &row.EpisodeNumber,
			&row.ShowFolderID, &row.ContentRating); err != nil {
			writeFailure(w, r, http.StatusInternalServerError, "db_error", err)
			return
		}
		items = append(items, itemSummary(row))
	}
	if err := rows.Err(); err != nil {
		writeFailure(w, r, http.StatusInternalServerError, "db_error", err)
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"genre": genre, "items": items})
}
