package main

import (
	"database/sql"
	"log"
)

// progressRecord is one viewing profile's progress on one item (FRD-002 FR-230): the row of
// the progress table, as read. It is the ONE in-memory form of progress, and JSON() is THE
// builder of the wire object {positionSeconds, durationSeconds, updatedAt} that /progress,
// /progress/all, the sync feed, every itemSummary list element and the TV episode lists
// answer with. Rule 9: a new endpoint that emits progress builds it through JSON(); never
// hand-build the map again (progress_shape_test.go compares every site byte for byte).
//
// Units: both counts are whole seconds. The wire carries them as bare integers, updatedAt as
// the RFC 3339 string the progress write stamped. int64 is the one in-memory type, so a
// caller never asserts .(int) on a map value.
type progressRecord struct {
	PositionSeconds int64
	DurationSeconds int64
	UpdatedAt       string
}

// JSON is the wire object. All three keys are always present; an item with no progress has no
// progressRecord at all (the caller omits the key, or answers null, per its endpoint).
func (p progressRecord) JSON() map[string]any {
	return map[string]any{
		"positionSeconds": p.PositionSeconds,
		"durationSeconds": p.DurationSeconds,
		"updatedAt":       p.UpdatedAt,
	}
}

// progressFromNull turns the three LEFT JOINed progress columns of an item query into a
// record. ok is false when the item has no progress row: position or duration is NULL. The
// progress columns are NOT NULL, so a joined row yields both or neither; requiring both is
// the one presence rule for every site.
func progressFromNull(pos, dur sql.NullInt64, updatedAt sql.NullString) (progressRecord, bool) {
	if !pos.Valid || !dur.Valid {
		return progressRecord{}, false
	}
	return progressRecord{PositionSeconds: pos.Int64, DurationSeconds: dur.Int64, UpdatedAt: updatedAt.String}, true
}

// progressSelect is the column list every direct read of the progress table selects, in the
// order scanProgressRows expects.
const progressSelect = "item_id, position_seconds, duration_seconds, updated_at"

// scanProgressRows drains rows selected with progressSelect into item id -> record. A row that
// fails to scan is logged with site and skipped; one bad row does not hide the rest.
func scanProgressRows(rows *sql.Rows, site string) map[string]progressRecord {
	out := make(map[string]progressRecord)
	for rows.Next() {
		var itemID string
		var rec progressRecord
		if err := rows.Scan(&itemID, &rec.PositionSeconds, &rec.DurationSeconds, &rec.UpdatedAt); err != nil {
			log.Printf("%s: scan progress row: %v", site, err)
			continue
		}
		out[itemID] = rec
	}
	if err := rows.Err(); err != nil {
		log.Printf("%s: iterate progress rows: %v", site, err)
	}
	return out
}

// progressMapJSON is the {itemId: progress object} body of /progress and /progress/all.
func progressMapJSON(m map[string]progressRecord) map[string]any {
	out := make(map[string]any, len(m))
	for id, rec := range m {
		out[id] = rec.JSON()
	}
	return out
}
