package main

// More Like This (FR-151, TASK-747): GET /api/v1/items/{id}/similar?limit=N.
//
// Everything is computed from the local library; there is no outbound call. The shape of the
// work is one candidate query plus scoring in Go:
//
//  1. One PK lookup reads the seed (type, year, genres, show, certification).
//  2. One SELECT, computed over the seed's collections, reads which of collectionDefs the seed
//     belongs to (the same membership rule the Collections rails use, so "same collection"
//     has one definition).
//  3. One candidate SELECT pulls only titles that share a genre with the seed or belong to one
//     of the seed's collections, already held to the viewer's ceiling in the WHERE (FR-250),
//     capped at similarCandidateCap rows.
//  4. Scoring, episode collapsing and the sort run in Go over those rows.
//
// genres is a comma-joined TEXT column with no index (see handleItems), so step 3 is a single
// filtered pass over items, not an index seek; the cap bounds what is held and scored, and
// the response is a handful of rows.

import (
	"database/sql"
	"errors"
	"log"
	"net/http"
	"path/filepath"
	"sort"
	"strings"

	"github.com/go-chi/chi/v5"
)

const (
	similarDefaultLimit = 12
	similarMaxLimit     = 30
	// similarCandidateCap bounds the rows one request will load and score.
	similarCandidateCap = 2000

	// Scoring weights (FR-151). A shared genre or collection is the strongest signal; the
	// decade and the movie/show kind only separate titles that already share one of those.
	similarGenreWeight          = 3.0 // per shared genre
	similarCollectionWeight     = 4.0 // per shared collection
	similarSameDecadeWeight     = 2.0
	similarAdjacentDecadeWeight = 1.0
	similarSameKindWeight       = 1.5
)

// similarity is what the score looks at on one title.
type similarity struct {
	genres map[string]bool
	year   sql.NullInt64
	show   bool // an episode (a show), as opposed to a movie
}

// splitGenres turns the comma-joined genres column into a set ("Action, Comedy" and
// "Action,Comedy" read the same).
func splitGenres(csv string) map[string]bool {
	out := map[string]bool{}
	for _, g := range strings.Split(csv, ",") {
		if g = strings.TrimSpace(g); g != "" {
			out[g] = true
		}
	}
	return out
}

// similarityScore is THE scoring rule of More Like This: weighted shared genres, shared
// collections, release-decade proximity and same kind (movie vs show).
func similarityScore(seed, cand similarity, sharedCollections int) float64 {
	score := float64(sharedCollections) * similarCollectionWeight
	for g := range cand.genres {
		if seed.genres[g] {
			score += similarGenreWeight
		}
	}
	if seed.year.Valid && cand.year.Valid && seed.year.Int64 > 0 && cand.year.Int64 > 0 {
		diff := seed.year.Int64/10 - cand.year.Int64/10
		switch {
		case diff == 0:
			score += similarSameDecadeWeight
		case diff == 1 || diff == -1:
			score += similarAdjacentDecadeWeight
		}
	}
	if seed.show == cand.show {
		score += similarSameKindWeight
	}
	return score
}

type similarCandidate struct {
	row    itemSummaryRow
	genres map[string]bool
	path   string
	hits   int // how many of the seed's collections this title is in
	score  float64
}

// similarEntry is one title in the answer: a movie, or a whole show collapsed from its
// episodes (the convention of the Collections rails: one entry, represented by one episode).
type similarEntry struct {
	rep       itemSummaryRow
	display   string
	year      sql.NullInt64
	addedAt   string
	score     float64
	hasPoster bool
}

// handleItemSimilar answers GET /items/{id}/similar. 404 for an unknown id, 403
// content_restricted for a seed above the viewer's ceiling (the same answer as GET
// /items/{id}), otherwise {"items":[summary...]} best match first.
func (s *Server) handleItemSimilar(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	limit := clampInt(parseInt(r.URL.Query().Get("limit"), similarDefaultLimit), 1, similarMaxLimit)

	v, ok := s.requestViewer(w, r)
	if !ok {
		return
	}

	var seedType, seedPath string
	var seedYear sql.NullInt64
	var seedGenres, seedShow, seedRating sql.NullString
	err := s.db.QueryRow(`SELECT type, year, genres, show_name, path, content_rating FROM items WHERE id = ?`, id).
		Scan(&seedType, &seedYear, &seedGenres, &seedShow, &seedPath, &seedRating)
	if errors.Is(err, sql.ErrNoRows) {
		writeErr(w, http.StatusNotFound, "not_found")
		return
	}
	if err != nil {
		writeFailure(w, r, http.StatusInternalServerError, "db_error", err)
		return
	}
	if v.above(seedRating, seedType, seedYear) { // FR-250: refused, naming the real cause (as GET /items/{id})
		writeContentRestricted(w)
		return
	}

	seed := similarity{genres: splitGenres(seedGenres.String), year: seedYear, show: seedType == "episode"}

	// Which collections the seed is in: one SELECT, one 0/1 column per definition.
	seedCols, err := s.seedCollections(id)
	if err != nil {
		writeFailure(w, r, http.StatusInternalServerError, "db_error", err)
		return
	}

	items := make([]map[string]any, 0, limit)
	if len(seed.genres) == 0 && len(seedCols) == 0 {
		// Nothing to be similar by: an honest empty list, not a guess.
		writeJSON(w, http.StatusOK, map[string]any{"items": items})
		return
	}

	cands, err := s.similarCandidates(v, id, seed, seedCols)
	if err != nil {
		writeFailure(w, r, http.StatusInternalServerError, "db_error", err)
		return
	}
	if len(cands) >= similarCandidateCap {
		log.Printf("similar: candidate cap %d reached for %s; ranking the first %d by season/path", similarCandidateCap, id, len(cands))
	}

	for _, e := range s.rankSimilar(seed, seedType, seedPath, seedShow, cands, limit) {
		row := e.rep
		if row.Type == "episode" && e.display != "" {
			row.Title = e.display
			row.ShowName = sql.NullString{String: e.display, Valid: true}
			row.Year = e.year
			row.AddedAt = e.addedAt
		}
		items = append(items, itemSummary(row))
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

// seedCollections returns the definitions (collectionDefs, every audience: they only steer
// the ranking, they are not offered to the viewer here) that the item is a member of.
func (s *Server) seedCollections(itemID string) ([]collectionDef, error) {
	var exprs []string
	var args []any
	for _, d := range collectionDefs {
		clause, cargs := d.membershipClause()
		exprs = append(exprs, "("+clause+")")
		args = append(args, cargs...)
	}
	args = append(args, itemID)
	hits := make([]int, len(collectionDefs))
	dest := make([]any, len(hits))
	for i := range hits {
		dest[i] = &hits[i]
	}
	if err := s.db.QueryRow("SELECT "+strings.Join(exprs, ", ")+" FROM items i WHERE i.id = ?", args...).Scan(dest...); err != nil {
		return nil, err
	}
	var in []collectionDef
	for i, h := range hits {
		if h != 0 {
			in = append(in, collectionDefs[i])
		}
	}
	return in, nil
}

// similarCandidates loads titles sharing a genre with the seed or a collection the seed is
// in. The ceiling goes through v.andVisibleFrag, the one helper every list endpoint uses
// (FR-250); the seed itself is excluded.
func (s *Server) similarCandidates(v viewer, seedID string, seed similarity, seedCols []collectionDef) ([]similarCandidate, error) {
	var colExprs []string
	var colArgs []any
	for _, d := range seedCols {
		clause, cargs := d.membershipClause()
		colExprs = append(colExprs, "("+clause+")")
		colArgs = append(colArgs, cargs...)
	}

	var anyOf []string
	var whereArgs []any
	if len(seed.genres) > 0 {
		names := make([]string, 0, len(seed.genres))
		for g := range seed.genres {
			names = append(names, g)
		}
		sort.Strings(names)
		clause, gargs := collectionDef{Genres: names}.membershipClause()
		anyOf = append(anyOf, clause)
		whereArgs = append(whereArgs, gargs...)
	}
	anyOf = append(anyOf, colExprs...)
	whereArgs = append(whereArgs, colArgs...)

	visFrag, visArgs := v.andVisibleFrag("i.content_rating")
	whereArgs = append(whereArgs, visArgs...)

	selectCols := ""
	for _, e := range colExprs {
		selectCols += ", " + e
	}
	// Placeholder order follows the SQL text: select-list collection args, the progress join,
	// the seed id, then the WHERE.
	args := append([]any{}, colArgs...)
	args = append(args, v.ProfileID, seedID)
	args = append(args, whereArgs...)
	args = append(args, similarCandidateCap)

	rows, err := s.db.Query(`
		SELECT i.id, i.type, i.title, i.year, i.duration_seconds, i.added_at, i.rating,
		       i.poster_path, i.backdrop_path, i.show_name, i.season_number, i.episode_number,
		       p.position_seconds, p.duration_seconds, p.updated_at,
		       i.show_folder_id, i.content_rating, i.genres, i.path`+selectCols+`
		FROM items i
		LEFT JOIN progress p ON p.item_id = i.id AND p.profile_id = ?
		WHERE i.id != ? AND (`+strings.Join(anyOf, " OR ")+`)`+visFrag+`
		ORDER BY i.season_number ASC, i.path ASC
		LIMIT ?`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []similarCandidate
	for rows.Next() {
		var c similarCandidate
		var genres sql.NullString
		colHits := make([]int, len(colExprs))
		dest := []any{&c.row.ID, &c.row.Type, &c.row.Title, &c.row.Year, &c.row.Duration, &c.row.AddedAt, &c.row.Rating,
			&c.row.PosterPath, &c.row.BackdropPath, &c.row.ShowName, &c.row.SeasonNumber, &c.row.EpisodeNumber,
			&c.row.ProgPos, &c.row.ProgDur, &c.row.ProgUpdatedAt,
			&c.row.ShowFolderID, &c.row.ContentRating, &genres, &c.path}
		for i := range colHits {
			dest = append(dest, &colHits[i])
		}
		if err := rows.Scan(dest...); err != nil {
			return nil, err
		}
		c.genres = splitGenres(genres.String)
		for _, h := range colHits {
			if h != 0 {
				c.hits++
			}
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// rankSimilar scores the candidates, collapses episodes to one entry per show (with the
// codebase's one show grouping, groupEpisodesByShow), drops the seed's own show, and returns
// the best `limit` entries.
func (s *Server) rankSimilar(seed similarity, seedType, seedPath string, seedShow sql.NullString, cands []similarCandidate, limit int) []similarEntry {
	// The seed rides along as ref 0 so its show resolves by the same rule as the candidates'.
	refs := make([]episodeRef, 0, len(cands)+1)
	refs = append(refs, episodeRef{})
	if seedType == "episode" {
		refs[0] = episodeRef{Path: seedPath, ShowName: seedShow}
	}
	for _, c := range cands {
		if c.row.Type == "episode" {
			refs = append(refs, episodeRef{Path: c.path, ShowName: c.row.ShowName})
		} else {
			refs = append(refs, episodeRef{})
		}
	}
	groups := groupEpisodesByShow(refs, filepath.Clean(s.cfg.TVPath)+"/")
	seedKey := groups[0].Key

	var entries []*similarEntry
	byKey := map[string]*similarEntry{}
	for i := range cands {
		c := &cands[i]
		g := groups[i+1]
		cs := similarity{genres: c.genres, year: c.row.Year, show: c.row.Type == "episode"}
		c.score = similarityScore(seed, cs, c.hits)
		hasPoster := c.row.PosterPath.Valid && c.row.PosterPath.String != ""

		if c.row.Type == "episode" && seedType == "episode" {
			// Never offer the show being watched as similar to itself.
			if seedKey != "" && g.Key == seedKey {
				continue
			}
			if seedKey == "" && seedShow.Valid && seedShow.String != "" && c.row.ShowName == seedShow {
				continue
			}
		}

		if c.row.Type == "episode" && g.Folder != "" {
			display := g.Folder
			if g.ShowName.Valid && g.ShowName.String != "" {
				display = g.ShowName.String
			}
			if e, seen := byKey[g.Key]; seen {
				if c.score > e.score {
					e.score = c.score
				}
				if c.row.AddedAt > e.addedAt {
					e.addedAt = c.row.AddedAt
				}
				if c.row.Year.Valid && (!e.year.Valid || c.row.Year.Int64 < e.year.Int64) {
					e.year = c.row.Year
				}
				// The first episode WITH artwork represents the show, as in /tv/shows.
				if hasPoster && !e.hasPoster {
					e.rep = c.row
					e.hasPoster = true
				}
				continue
			}
			e := &similarEntry{rep: c.row, display: display, year: c.row.Year, addedAt: c.row.AddedAt, score: c.score, hasPoster: hasPoster}
			byKey[g.Key] = e
			entries = append(entries, e)
			continue
		}
		entries = append(entries, &similarEntry{rep: c.row, year: c.row.Year, addedAt: c.row.AddedAt, score: c.score, hasPoster: hasPoster})
	}

	sort.SliceStable(entries, func(a, b int) bool {
		x, y := entries[a], entries[b]
		if x.score != y.score {
			return x.score > y.score
		}
		if x.rep.Rating.Valid != y.rep.Rating.Valid {
			return x.rep.Rating.Valid
		}
		if x.rep.Rating.Valid && x.rep.Rating.Float64 != y.rep.Rating.Float64 {
			return x.rep.Rating.Float64 > y.rep.Rating.Float64
		}
		xt, yt := strings.ToLower(entryTitle(x)), strings.ToLower(entryTitle(y))
		if xt != yt {
			return xt < yt
		}
		return x.rep.ID < y.rep.ID
	})
	if len(entries) > limit {
		entries = entries[:limit]
	}
	out := make([]similarEntry, len(entries))
	for i, e := range entries {
		out[i] = *e
	}
	return out
}

func entryTitle(e *similarEntry) string {
	if e.display != "" {
		return e.display
	}
	return e.rep.Title
}
