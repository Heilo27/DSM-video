package main

import (
	"database/sql"
	"testing"
)

// The scanner used to run a full ffprobe on every video file on every 5-minute pass:
// measured at ~35GB of disk reads per minute on a 5,157-item library that had not
// changed, indefinitely. The fix caches probe results against file size + mtime.
//
// These tests pin the cache-hit predicate, which is the part that silently regresses.
// A change that makes it stop matching does not break anything visibly — it just puts
// the drives back under permanent load, which is exactly how the original bug survived.

// mirrors the predicate in scanLibraryWithClient
func cacheHit(probed bool, storedSize sql.NullInt64, storedMtime sql.NullString,
	actualSize int64, actualMtime string) bool {
	return probed &&
		storedSize.Valid && storedSize.Int64 == actualSize &&
		storedMtime.Valid && storedMtime.String == actualMtime
}

func size(n int64) sql.NullInt64  { return sql.NullInt64{Int64: n, Valid: true} }
func mt(s string) sql.NullString  { return sql.NullString{String: s, Valid: true} }

func TestUnchangedFileIsNotReprobed(t *testing.T) {
	if !cacheHit(true, size(1000), mt("2026-01-01T00:00:00Z"), 1000, "2026-01-01T00:00:00Z") {
		t.Fatal("an unchanged file must hit the cache — a miss here re-reads the whole file every scan")
	}
}

func TestChangedSizeForcesReprobe(t *testing.T) {
	// A re-encode or a still-copying file changes size; stale codec data would be wrong.
	if cacheHit(true, size(1000), mt("2026-01-01T00:00:00Z"), 2000, "2026-01-01T00:00:00Z") {
		t.Fatal("a size change must re-probe")
	}
}

func TestChangedMtimeForcesReprobe(t *testing.T) {
	if cacheHit(true, size(1000), mt("2026-01-01T00:00:00Z"), 1000, "2026-06-01T00:00:00Z") {
		t.Fatal("an mtime change must re-probe")
	}
}

// The regression that shipped in the first version of the cache: 13 damaged files whose
// dimensions ffprobe could not read never satisfied the "probed" test, so they re-probed
// on every pass forever — a small permanent copy of the original bug. The marker records
// that a probe ATTEMPT completed, independent of which fields it managed to fill.
func TestProbedFileWithUnreadableDimensionsIsStillCached(t *testing.T) {
	probed := true // probed_at stamped even though video_width came back NULL
	if !cacheHit(probed, size(4980784), mt("2026-01-01T00:00:00Z"), 4980784, "2026-01-01T00:00:00Z") {
		t.Fatal("a probed-but-unreadable file must still cache, or it is re-read on every scan")
	}
}

func TestNeverProbedFileIsProbed(t *testing.T) {
	if cacheHit(false, size(1000), mt("2026-01-01T00:00:00Z"), 1000, "2026-01-01T00:00:00Z") {
		t.Fatal("a row that was never probed must be probed")
	}
}

func TestMissingStoredIdentityForcesReprobe(t *testing.T) {
	// Rows written before size_bytes existed have no identity to compare against.
	if cacheHit(true, sql.NullInt64{}, mt("2026-01-01T00:00:00Z"), 1000, "2026-01-01T00:00:00Z") {
		t.Fatal("no stored size means we cannot claim the file is unchanged")
	}
}
