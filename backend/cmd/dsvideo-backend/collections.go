package main

// Collections (FRD-002 §9, TASK-918, TASK-1054): studio, theme and kid-genre groupings. Kids'
// profiles browse them in place of the genre list, Teens get the studio and theme ones as an
// extra row, and Adult profiles are offered none (FR-274).
//
// collectionDefs below is the ONE home for every collection id, title and membership rule
// (FR-271, AC-002-66). The endpoints, the visibility tiers and the tests all read it; adding
// a collection is a data change there and nowhere else.

import (
	"database/sql"
	"fmt"
	"net/http"
	"path/filepath"
	"sort"
	"strings"

	agerating "dsvideo/backend/internal/rating"

	"github.com/go-chi/chi/v5"
)

// Collection kinds (FR-271).
const (
	collectionKindStudio = "studio"
	collectionKindTheme  = "theme"
	collectionKindGenre  = "genre"
)

// Collection audiences (FR-274). "kids" collections are offered only to profiles at or below
// kidsMaxAgeLevel; "all" collections are offered to every profile that is offered collections
// at all (offersCollections).
const (
	collectionAudienceAll  = "all"
	collectionAudienceKids = "kids"
)

// kidsMaxAgeLevel is the highest ceiling that counts as a kids' profile: Older Kids (FR-270).
const kidsMaxAgeLevel = 2

// isKidsLevel is THE rule for "is a profile with this ceiling a kids' profile" (FR-270). It
// decides which collections a profile is offered (FR-274) and is sent to clients as the
// Profile "kids" field, so no client holds its own copy of the threshold (TASK-921).
func isKidsLevel(maxAgeLevel int) bool { return maxAgeLevel <= kidsMaxAgeLevel }

// offersCollections is THE rule for "is a profile with this ceiling offered collections at
// all" (FR-274, Ryan 2026-10-18): every profile with a rating ceiling is; the unrestricted
// Adult ceiling is not. It is defined off the rating ladder (agerating.Restricted), so there
// is no level literal here. It gates both endpoints and is sent to clients as the Profile
// "offersCollections" field, so no client holds its own copy of the cutoff.
func offersCollections(maxAgeLevel int) bool { return agerating.Restricted(maxAgeLevel) }

// TMDb separates production companies from TV networks, and numbers them independently:
// company 2 is Walt Disney Pictures, network 2 is ABC. An id without its kind is ambiguous,
// so a rule entry always names both (FR-271).
const (
	tagKindCompany = "company"
	tagKindNetwork = "network"
)

// companyRef is one studio/network entry of a membership rule.
type companyRef struct {
	Kind string // tagKindCompany | tagKindNetwork
	ID   int
}

// collectionDef is one collection: identity, copy and membership rule. A title is a member
// if it has ANY of Companies, OR any of Keywords, OR any of Genres (FR-271). Genres are
// stored as names, not ids.
type collectionDef struct {
	ID        string
	Title     string
	Kind      string
	Audience  string
	Companies []companyRef
	Keywords  []int
	Genres    []string
}

// collectionDefs is the whole definition, in display order (FR-272). Every TMDb id was
// checked against themoviedb.org on 2026-10-17: company 3 Pixar, 2 Walt Disney Pictures,
// 6125 Walt Disney Animation Studios, 3166 Walt Disney Productions, 521 DreamWorks
// Animation, 6704 Illumination; keyword 207317 "christmas", 3335 "halloween".
//
// Keyword 65 ("holiday") is deliberately not used: on TMDb it mostly tags vacation films.
var collectionDefs = []collectionDef{
	{ID: "pixar", Title: "Pixar", Kind: collectionKindStudio, Audience: collectionAudienceAll,
		Companies: []companyRef{{tagKindCompany, 3}}},
	{ID: "disney", Title: "Disney", Kind: collectionKindStudio, Audience: collectionAudienceAll,
		Companies: []companyRef{{tagKindCompany, 2}, {tagKindCompany, 6125}, {tagKindCompany, 3166}}},
	{ID: "dreamworks", Title: "DreamWorks", Kind: collectionKindStudio, Audience: collectionAudienceAll,
		Companies: []companyRef{{tagKindCompany, 521}}},
	{ID: "illumination", Title: "Illumination", Kind: collectionKindStudio, Audience: collectionAudienceAll,
		Companies: []companyRef{{tagKindCompany, 6704}}},
	{ID: "holiday", Title: "Holiday", Kind: collectionKindTheme, Audience: collectionAudienceAll,
		Keywords: []int{207317}},
	{ID: "halloween", Title: "Halloween", Kind: collectionKindTheme, Audience: collectionAudienceAll,
		Keywords: []int{3335}},
	{ID: "animation", Title: "Animation", Kind: collectionKindGenre, Audience: collectionAudienceKids,
		Genres: []string{"Animation"}},
	{ID: "family", Title: "Family", Kind: collectionKindGenre, Audience: collectionAudienceKids,
		Genres: []string{"Family", "Kids"}},
}

// collectionsFor returns the definitions offered to v, in definition order (FR-274): every
// collection for a kids' profile, only the audience-all ones for Teens, none for Adult. The
// empty list is the Adult answer, so neither endpoint needs a tier branch of its own.
func collectionsFor(v viewer) []collectionDef {
	out := make([]collectionDef, 0, len(collectionDefs))
	if !offersCollections(v.MaxAgeLevel) {
		return out
	}
	kids := isKidsLevel(v.MaxAgeLevel)
	for _, d := range collectionDefs {
		if kids || d.Audience == collectionAudienceAll {
			out = append(out, d)
		}
	}
	return out
}

// collectionFor finds the definition with the given id among those offered to v.
func collectionFor(v viewer, id string) (collectionDef, bool) {
	for _, d := range collectionsFor(v) {
		if d.ID == id {
			return d, true
		}
	}
	return collectionDef{}, false
}

// membershipClause is the SQL predicate (over items aliased i) true for members of d, with
// its args. Every value is bound. A definition with no rules matches nothing.
func (d collectionDef) membershipClause() (string, []any) {
	var preds []string
	var args []any

	var byKind []string
	var kindArgs []any
	for _, kind := range []string{tagKindCompany, tagKindNetwork} {
		var ids []any
		for _, c := range d.Companies {
			if c.Kind == kind {
				ids = append(ids, c.ID)
			}
		}
		if len(ids) == 0 {
			continue
		}
		byKind = append(byKind, "(c.kind = ? AND c.company_id IN ("+placeholders(len(ids))+"))")
		kindArgs = append(kindArgs, kind)
		kindArgs = append(kindArgs, ids...)
	}
	if len(byKind) > 0 {
		preds = append(preds, "EXISTS (SELECT 1 FROM item_companies c WHERE c.item_id = i.id AND ("+
			strings.Join(byKind, " OR ")+"))")
		args = append(args, kindArgs...)
	}
	if len(d.Keywords) > 0 {
		preds = append(preds, "EXISTS (SELECT 1 FROM item_keywords k WHERE k.item_id = i.id AND k.keyword_id IN ("+
			placeholders(len(d.Keywords))+"))")
		for _, k := range d.Keywords {
			args = append(args, k)
		}
	}
	for _, g := range d.Genres {
		// genres is a comma-joined column; padding both sides makes the match exact
		// ("Family" must not match "Family Drama"). Same expression /suggested uses.
		preds = append(preds, `(',' || REPLACE(IFNULL(i.genres, ''), ', ', ',') || ',') LIKE ? ESCAPE '\'`)
		args = append(args, "%,"+escapeLike(g)+",%")
	}
	if len(preds) == 0 {
		return "0", nil
	}
	return "(" + strings.Join(preds, " OR ") + ")", args
}

func placeholders(n int) string {
	if n <= 0 {
		return ""
	}
	return strings.TrimSuffix(strings.Repeat("?,", n), ",")
}

// collectionMember is one title in a collection: a movie, or a whole show represented by
// one of its episodes (the same convention /just-added uses, so clients open it the same way).
type collectionMember struct {
	item      map[string]any
	title     string
	year      sql.NullInt64
	addedAt   string
	rating    sql.NullFloat64
	hasPoster bool
	posterID  string
}

// collectionMembers returns the titles of d visible to v, each movie once and each show once
// (never per episode, AC-002-63). The ceiling is in the WHERE (FR-250), so counts and pages
// describe only what v may see; there is no LIMIT before the show grouping.
func (s *Server) collectionMembers(v viewer, d collectionDef) ([]collectionMember, error) {
	where, args := d.membershipClause()
	visFrag, visArgs := v.andVisibleFrag("i.content_rating")
	args = append(args, visArgs...)

	rows, err := s.db.Query(`
		SELECT i.id, i.type, i.title, i.year, i.duration_seconds, i.added_at, i.rating,
		       i.poster_path, i.backdrop_path, i.show_name, i.season_number, i.episode_number,
		       i.library_id, i.path, i.content_rating
		FROM items i
		WHERE `+where+visFrag+`
		ORDER BY i.season_number ASC, i.path ASC`, args...)
	if err != nil {
		return nil, fmt.Errorf("collection %s members: %w", d.ID, err)
	}
	defer rows.Close()

	type row struct {
		id, typ, title, addedAt, libID, folder string
		year, duration, season, episode        sql.NullInt64
		rating                                 sql.NullFloat64
		posterPath, backdropPath, showName     sql.NullString
		contentRating                          *string
	}
	tvRoot := filepath.Clean(s.cfg.TVPath) + "/"
	var all []row
	var refs []episodeRef // parallel to all; zero for a film, which groups nowhere
	for rows.Next() {
		var r row
		var path string
		if err := rows.Scan(&r.id, &r.typ, &r.title, &r.year, &r.duration, &r.addedAt, &r.rating,
			&r.posterPath, &r.backdropPath, &r.showName, &r.season, &r.episode,
			&r.libID, &path, &r.contentRating); err != nil {
			return nil, fmt.Errorf("collection %s scan: %w", d.ID, err)
		}
		var ref episodeRef
		if r.typ == "episode" {
			ref = episodeRef{Path: path, ShowName: r.showName}
		}
		all = append(all, r)
		refs = append(refs, ref)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("collection %s rows: %w", d.ID, err)
	}

	// The codebase's one answer for "which show is this episode part of", decided over the
	// collection's visible members (see groupEpisodesByShow).
	groups := groupEpisodesByShow(refs, tvRoot)

	var members []collectionMember
	showIdx := map[string]int{} // show group key → index in members
	for i, r := range all {
		hasPoster := r.posterPath.Valid && r.posterPath.String != ""
		r.folder = groups[i].Folder
		if r.typ == "episode" && r.folder != "" {
			showName := groups[i].ShowName
			key := groups[i].Key
			if i, seen := showIdx[key]; seen {
				m := &members[i]
				if r.addedAt > m.addedAt {
					m.addedAt = r.addedAt
					m.item["addedAt"] = r.addedAt
				}
				if r.year.Valid && (!m.year.Valid || r.year.Int64 < m.year.Int64) {
					m.year = r.year
					m.item["year"] = r.year.Int64
				}
				// The first episode WITH artwork represents the show, as in /tv/shows.
				if hasPoster && !m.hasPoster {
					s.collectionFillRepresentative(m, r.id, r.typ, r.libID, r.duration, r.rating, r.season, r.episode, r.posterPath, r.backdropPath, r.contentRating)
					m.hasPoster = true
					m.posterID = r.id
				}
				continue
			}
			display := r.folder
			if showName.Valid && showName.String != "" {
				display = showName.String
			}
			m := collectionMember{title: display, year: r.year, addedAt: r.addedAt, rating: r.rating, hasPoster: hasPoster}
			m.item = map[string]any{
				"id": r.id, "type": r.typ, "title": display,
				"year": nullIntToAny(r.year), "durationSeconds": nullIntToAny(r.duration),
				"addedAt": r.addedAt, "rating": nullFloatToAny(r.rating), "libraryId": r.libID,
				"posterImageId": nil, "backdropImageId": nil,
				"contentRating": r.contentRating, "ageLevel": agerating.LevelPtr(r.contentRating),
				"showName": display,
			}
			s.collectionFillRepresentative(&m, r.id, r.typ, r.libID, r.duration, r.rating, r.season, r.episode, r.posterPath, r.backdropPath, r.contentRating)
			if hasPoster {
				m.posterID = r.id
			}
			showIdx[key] = len(members)
			members = append(members, m)
			continue
		}

		m := collectionMember{title: r.title, year: r.year, addedAt: r.addedAt, rating: r.rating, hasPoster: hasPoster}
		m.item = map[string]any{
			"id": r.id, "type": r.typ, "title": r.title,
			"year": nullIntToAny(r.year), "durationSeconds": nullIntToAny(r.duration),
			"addedAt": r.addedAt, "rating": nullFloatToAny(r.rating), "libraryId": r.libID,
			"posterImageId": nil, "backdropImageId": nil,
			"contentRating": r.contentRating, "ageLevel": agerating.LevelPtr(r.contentRating),
		}
		if hasPoster {
			m.item["posterImageId"] = r.id
			m.posterID = r.id
		}
		if r.backdropPath.Valid && r.backdropPath.String != "" {
			m.item["backdropImageId"] = r.id
		}
		if r.showName.Valid && r.showName.String != "" {
			m.item["showName"] = r.showName.String
		}
		members = append(members, m)
	}
	return members, nil
}

// collectionFillRepresentative points a show's payload at one episode: its id, artwork,
// rating and episode fields. The show-level title/year/addedAt stay as aggregated.
func (s *Server) collectionFillRepresentative(m *collectionMember, id, typ, libID string,
	duration sql.NullInt64, rating sql.NullFloat64, season, episode sql.NullInt64,
	posterPath, backdropPath sql.NullString, contentRating *string) {
	m.item["id"] = id
	m.item["libraryId"] = libID
	m.item["durationSeconds"] = nullIntToAny(duration)
	m.item["rating"] = nullFloatToAny(rating)
	m.rating = rating
	m.item["contentRating"] = contentRating
	m.item["ageLevel"] = agerating.LevelPtr(contentRating)
	// Reset first: re-pointing at a better episode must not leave the previous one's artwork
	// or episode numbers on the payload.
	m.item["posterImageId"], m.item["backdropImageId"] = nil, nil
	delete(m.item, "seasonNumber")
	delete(m.item, "episodeNumber")
	if posterPath.Valid && posterPath.String != "" {
		m.item["posterImageId"] = id
	}
	if backdropPath.Valid && backdropPath.String != "" {
		m.item["backdropImageId"] = id
	}
	if season.Valid {
		m.item["seasonNumber"] = season.Int64
	}
	if episode.Valid {
		m.item["episodeNumber"] = episode.Int64
	}
}

// handleCollections serves GET /collections: the active profile's non-empty collections, in
// definition order, with visible counts (FR-273, FR-274, FR-275).
func (s *Server) handleCollections(w http.ResponseWriter, r *http.Request) {
	v, ok := s.requestViewer(w, r)
	if !ok {
		return
	}
	out := make([]map[string]any, 0, len(collectionDefs))
	for _, d := range collectionsFor(v) {
		members, err := s.collectionMembers(v, d)
		if err != nil {
			writeFailure(w, r, http.StatusInternalServerError, "db_error", fmt.Errorf("collections: %w", err))
			return
		}
		if len(members) == 0 {
			continue // FR-273: a collection with no visible titles is hidden.
		}
		// Representative poster: the most recently added visible member that has one.
		var poster any
		var newest string
		for _, m := range members {
			if m.posterID != "" && (poster == nil || m.addedAt > newest) {
				poster, newest = m.posterID, m.addedAt
			}
		}
		out = append(out, map[string]any{
			"id": d.ID, "title": d.Title, "kind": d.Kind,
			"itemCount": len(members), "posterImageId": poster,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"collections": out})
}

// handleCollectionItems serves GET /collections/{id}/items: one collection's visible titles,
// sorted and paged (FR-275). An id that is undefined, or not offered to this profile, is
// 404 unknown_collection. A collection the profile is offered but that has no visible titles
// answers 200 with total 0 (the client already hid it from /collections).
func (s *Server) handleCollectionItems(w http.ResponseWriter, r *http.Request) {
	v, ok := s.requestViewer(w, r)
	if !ok {
		return
	}
	d, found := collectionFor(v, chi.URLParam(r, "id"))
	if !found {
		writeErr(w, http.StatusNotFound, "unknown_collection")
		return
	}
	q := r.URL.Query()
	limit := clampInt(parseInt(q.Get("limit"), 10000), 1, 10000)
	offset := clampInt(parseInt(q.Get("offset"), 0), 0, 1_000_000)

	members, err := s.collectionMembers(v, d)
	if err != nil {
		writeFailure(w, r, http.StatusInternalServerError, "db_error", fmt.Errorf("collections: %w", err))
		return
	}
	sortCollectionMembers(members, q.Get("sort"), q.Get("order"))

	total := len(members)
	if offset > total {
		offset = total
	}
	end := offset + limit
	if end > total {
		end = total
	}
	items := make([]map[string]any, 0, end-offset)
	for _, m := range members[offset:end] {
		items = append(items, m.item)
	}
	writeJSON(w, http.StatusOK, map[string]any{"total": total, "items": items})
}

// sortCollectionMembers orders members by sort (title | year | addedAt | rating) and order
// (asc | desc). Unrecognised values fall back to the defaults: title ascending, and for the
// other keys descending (newest / highest first). Ties break on title then id so paging is
// stable. Titles with no year or rating always sort last.
func sortCollectionMembers(ms []collectionMember, sortKey, order string) {
	desc := sortKey == "year" || sortKey == "addedAt" || sortKey == "rating"
	switch strings.ToLower(order) {
	case "asc":
		desc = false
	case "desc":
		desc = true
	}
	lessKey := func(a, b collectionMember) (less, equal bool) {
		switch sortKey {
		case "year":
			if a.year.Valid != b.year.Valid {
				return a.year.Valid, false // missing last, regardless of direction
			}
			if a.year.Int64 == b.year.Int64 {
				return false, true
			}
			return a.year.Int64 < b.year.Int64 != desc, false
		case "addedAt":
			if a.addedAt == b.addedAt {
				return false, true
			}
			return a.addedAt < b.addedAt != desc, false
		case "rating":
			if a.rating.Valid != b.rating.Valid {
				return a.rating.Valid, false
			}
			if a.rating.Float64 == b.rating.Float64 {
				return false, true
			}
			return a.rating.Float64 < b.rating.Float64 != desc, false
		default:
			at, bt := strings.ToLower(a.title), strings.ToLower(b.title)
			if at == bt {
				return false, true
			}
			return at < bt != desc, false
		}
	}
	sort.SliceStable(ms, func(i, j int) bool {
		if less, equal := lessKey(ms[i], ms[j]); !equal {
			return less
		}
		ti, tj := strings.ToLower(ms[i].title), strings.ToLower(ms[j].title)
		if ti != tj {
			return ti < tj
		}
		return fmt.Sprint(ms[i].item["id"]) < fmt.Sprint(ms[j].item["id"])
	})
}
