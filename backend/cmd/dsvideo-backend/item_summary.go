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
// progress when present. GET /items and GET /items/{id}/similar both call it; the other
// list endpoints still carry their own copies (listed in the TASK-747 report).
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
	putRating(item, r.ContentRating)

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
	if r.ProgPos.Valid {
		item["progress"] = map[string]any{
			"positionSeconds": r.ProgPos.Int64,
			"durationSeconds": r.ProgDur.Int64,
			"updatedAt":       r.ProgUpdatedAt.String,
		}
	}
	return item
}
