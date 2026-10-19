package main

import "database/sql"

// itemSummaryRow is one row of the standard item summary: the columns GET /items selects, as
// scanned. itemSummary turns it into the JSON object every title list answers with.
type itemSummaryRow struct {
	ID, Type, Title, AddedAt string
	Year, Duration           sql.NullInt64
	SeasonNumber             sql.NullInt64
	EpisodeNumber            sql.NullInt64
	Rating                   sql.NullFloat64
	PosterPath, BackdropPath sql.NullString
	ShowName                 sql.NullString
	ShowFolderID             sql.NullString
	ContentRating            sql.NullString
	// ProgPos/ProgDur/ProgUpdatedAt are the viewing profile's progress on this item
	// (FRD-002 FR-230); ProgPos is not Valid when there is none.
	ProgPos, ProgDur sql.NullInt64
	ProgUpdatedAt    sql.NullString
}

// itemSummary is THE builder of the standard item summary shape (the /items list element):
// id, type, title, year, durationSeconds, addedAt, rating, posterImageId, backdropImageId,
// contentRating, ageLevel, plus showName / seasonNumber / episodeNumber / showFolderId /
// progress when present. Every title-list endpoint builds its elements through it: /items,
// /items/{id}/similar, /search, the just-watched rail, playlists, downloads, the watchlist,
// the TV episode list, /just-added, /suggested and collection members. Endpoint extras
// (libraryId, a rail's own label) are set on top of the returned map, each with a comment.
// Documented exceptions, which are not item lists: /tv/shows (a show aggregate) and the sync
// feed (a typed, account-scoped record).
// Rule 9: a new list endpoint calls this; never hand-build the shape again.
func itemSummary(r itemSummaryRow) map[string]any {
	item := map[string]any{
		"id":              r.ID,
		"type":            r.Type,
		"title":           r.Title,
		"year":            nullIntToAny(r.Year),
		"durationSeconds": nullIntToAny(r.Duration),
		"addedAt":         r.AddedAt,
		"rating":          nullFloatToAny(r.Rating),
		"posterImageId":   nil,
		"backdropImageId": nil,
	}
	putRating(item, r.ContentRating, r.Type, r.Year)

	if r.PosterPath.Valid && r.PosterPath.String != "" {
		item["posterImageId"] = r.ID
	}
	if r.BackdropPath.Valid && r.BackdropPath.String != "" {
		item["backdropImageId"] = r.ID
	}
	if r.ShowName.Valid && r.ShowName.String != "" {
		item["showName"] = r.ShowName.String
	}
	if r.SeasonNumber.Valid {
		item["seasonNumber"] = r.SeasonNumber.Int64
	}
	if r.EpisodeNumber.Valid {
		item["episodeNumber"] = r.EpisodeNumber.Int64
	}
	if r.ShowFolderID.Valid && r.ShowFolderID.String != "" {
		item["showFolderId"] = r.ShowFolderID.String
	}
	if rec, ok := progressFromNull(r.ProgPos, r.ProgDur, r.ProgUpdatedAt); ok {
		item["progress"] = rec.JSON()
	}
	return item
}
