package main

import "testing"

// A list response must never contain two rows with the same id.
//
// This is not an API-tidiness rule. Clients key rendering on identity, and SwiftUI's ForEach
// COLLAPSES rows that share a key — so a duplicate id does not appear as a duplicate, it
// appears as a MISSING row, frequently a neighbouring one. Star Trek: The Next Generation
// disappeared from a real Apple TV that way: the server held all 176 episodes and a valid
// poster, and a collision elsewhere in the list removed it from the grid.
//
// The cause was fixed upstream (resolveFolderShowNames). These pin the guard, because the
// grouping code is not the only thing that can emit a collision and the failure is invisible
// at every layer between the handler and the screen.

func row(id, title string) map[string]any {
	return map[string]any{"id": id, "title": title}
}

func TestDuplicateIDsAreDroppedNotPassedThrough(t *testing.T) {
	// The exact shape seen live: four shows duplicated, the second of each pair being the
	// less complete record.
	in := []map[string]any{
		row("NCIS", "NCIS"),
		row("Shameless", "Shameless"),
		row("NCIS", "NCIS"),
		row("Star Trek The Next Generation", "Star Trek: The Next Generation"),
		row("Shameless", "Shameless"),
	}

	out := dedupeByID(in, "/test")

	if len(out) != 3 {
		t.Fatalf("expected 3 unique rows, got %d", len(out))
	}
	seen := map[string]int{}
	for _, r := range out {
		seen[r["id"].(string)]++
	}
	for id, n := range seen {
		if n != 1 {
			t.Errorf("id %q still appears %d times after dedupe", id, n)
		}
	}
	// The row that was never duplicated must survive — it is the one that went missing on
	// the device, and it is the whole point of the guard.
	if seen["Star Trek The Next Generation"] != 1 {
		t.Error("an unrelated row was lost while removing duplicates")
	}
}

// Keeps the FIRST occurrence: rows arrive sorted for display, so the first is the one the
// user expects, and the duplicate is by definition the less complete half of the split.
func TestDedupeKeepsTheFirstOccurrence(t *testing.T) {
	in := []map[string]any{
		{"id": "S", "title": "Shameless", "episodeCount": 134},
		{"id": "S", "title": "Shameless", "episodeCount": 6},
	}
	out := dedupeByID(in, "/test")
	if len(out) != 1 {
		t.Fatalf("expected 1 row, got %d", len(out))
	}
	if got := out[0]["episodeCount"]; got != 134 {
		t.Errorf("kept the wrong row: episodeCount=%v, want 134", got)
	}
}

// A row with no id is its own defect, but DROPPING it would hide content — which is exactly
// what this guard exists to prevent. It must pass through.
func TestRowsWithoutAnIDAreKept(t *testing.T) {
	in := []map[string]any{
		{"title": "No ID Here"},
		row("A", "A"),
		{"title": "Also No ID"},
	}
	out := dedupeByID(in, "/test")
	if len(out) != 3 {
		t.Fatalf("a row without an id was dropped: got %d rows, want 3", len(out))
	}
}

// The common case must be untouched, and must not reorder.
func TestUniqueRowsPassThroughUnchangedAndInOrder(t *testing.T) {
	in := []map[string]any{row("a", "A"), row("b", "B"), row("c", "C")}
	out := dedupeByID(in, "/test")
	if len(out) != 3 {
		t.Fatalf("expected 3 rows, got %d", len(out))
	}
	for i, want := range []string{"a", "b", "c"} {
		if got := out[i]["id"]; got != want {
			t.Errorf("row %d is %v, want %v — dedupe must not reorder", i, got, want)
		}
	}
}

func TestDedupeHandlesEmptyInput(t *testing.T) {
	if out := dedupeByID(nil, "/test"); len(out) != 0 {
		t.Errorf("nil input produced %d rows", len(out))
	}
	if out := dedupeByID([]map[string]any{}, "/test"); len(out) != 0 {
		t.Errorf("empty input produced %d rows", len(out))
	}
}
