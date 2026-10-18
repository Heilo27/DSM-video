package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"

	"dsvideo/backend/internal/metadata"
)

// castImagePrefix marks an image id as a cast member's photo rather than an item id (FR-150).
// Item ids are opaque hashes that never start with it, so /api/v1/images/{id} serves both.
const castImagePrefix = "cast-"

// castImageID is the one place a TMDb person id becomes the image id the detail response
// hands out; parseCastImageID is its inverse.
func castImageID(personID int) string {
	return castImagePrefix + strconv.Itoa(personID)
}

// parseCastImageID reports whether id names a cast photo and which TMDb person it is for. An
// id with the prefix but no positive integer after it is still a cast id (isCast true would
// route it to a 404 rather than the item lookup), so it returns (0, true) and the handler
// answers image_not_found.
func parseCastImageID(id string) (personID int, isCast bool) {
	rest, ok := strings.CutPrefix(id, castImagePrefix)
	if !ok {
		return 0, false
	}
	n, err := strconv.Atoi(rest)
	if err != nil || n <= 0 {
		return 0, true
	}
	return n, true
}

// serveCastImage serves one cast member's profile photo through the image cache, always at
// TMDb's w185 profile size (the size the 56-80 pt cast row needs on 3x screens; TMDb profile
// photos only come in w45, w185, h632 and original, so the ?w= poster ladder does not apply).
//
// A photo is not a title: it carries no rating, so the age ceiling does not gate it and the
// route needs no viewer. It names a person only, never the titles they appear in.
func (s *Server) serveCastImage(w http.ResponseWriter, r *http.Request, personID int) {
	if personID <= 0 {
		writeErr(w, http.StatusNotFound, "image_not_found")
		return
	}
	if s.imageCache == nil {
		writeFailure(w, r, http.StatusServiceUnavailable, "image_cache_unavailable", errImageCacheUnavailable)
		return
	}
	profilePath, err := s.castProfilePath(r, personID)
	if errors.Is(err, sql.ErrNoRows) {
		writeErr(w, http.StatusNotFound, "no_image_available")
		return
	}
	if err != nil {
		writeFailure(w, r, http.StatusInternalServerError, "db_error", fmt.Errorf("cast photo lookup %d: %w", personID, err))
		return
	}
	cached, err := s.imageCache.GetOrCacheTMDbImage(r.Context(), profilePath, metadata.ImageTypeProfile, metadata.ImageSizeW185)
	if err != nil {
		log.Printf("Failed to cache cast photo %d: %v", personID, err)
		writeErr(w, http.StatusNotFound, "image_not_found")
		return
	}
	w.Header().Set("Cache-Control", "public, max-age=604800") // 7 days, as every other image
	http.ServeFile(w, r, cached)
}

// castProfilePath returns the TMDb profile path stored for a person, or sql.ErrNoRows when no
// title has a photo for them. The same person has the same photo on every title; the most
// recently stored non-empty one wins if TMDb changed it between fetches.
func (s *Server) castProfilePath(r *http.Request, personID int) (string, error) {
	var p string
	err := s.db.QueryRowContext(r.Context(),
		`SELECT profile_path FROM item_cast WHERE tmdb_person_id = ? AND profile_path != '' LIMIT 1`,
		personID).Scan(&p)
	return p, err
}

// loadCastMembers is the detail response's "castMembers" array (FR-150): the billed cast in
// billing order, each {personId, name, character, imageId}. imageId is castImageID(personId)
// when TMDb has a photo for the person and null when it has none; clients fetch it from
// /api/v1/images/{imageId}.
//
// A title fetched before cast photos shipped has no item_cast rows yet, only the comma-joined
// cast_names. Those names are returned with personId, character and imageId null, so a client
// reads one array either way and shows initials where there is no photo; the cast backfill
// (POST /admin/metadata/refresh?scope=cast) upgrades such titles to full rows. The result is
// never nil, so the JSON is [] rather than null.
func (s *Server) loadCastMembers(ctx context.Context, itemID, legacyCastNames string) ([]map[string]any, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT tmdb_person_id, name, character, profile_path FROM item_cast WHERE item_id = ? ORDER BY ordinal`,
		itemID)
	if err != nil {
		return nil, fmt.Errorf("query item_cast: %w", err)
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var personID int
		var name, character, profilePath string
		if err := rows.Scan(&personID, &name, &character, &profilePath); err != nil {
			return nil, fmt.Errorf("scan item_cast: %w", err)
		}
		m := map[string]any{"personId": personID, "name": name, "character": nil, "imageId": nil}
		if character != "" {
			m["character"] = character
		}
		if profilePath != "" {
			m["imageId"] = castImageID(personID)
		}
		out = append(out, m)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate item_cast: %w", err)
	}
	if len(out) > 0 {
		return out, nil
	}
	for _, name := range strings.Split(legacyCastNames, ",") {
		if name = strings.TrimSpace(name); name != "" {
			out = append(out, map[string]any{"personId": nil, "name": name, "character": nil, "imageId": nil})
		}
	}
	return out, nil
}
