package main

import "testing"

// A show id must be unique, by construction rather than by luck.
//
// The id was the folder name, and one folder can legitimately hold TWO shows: Daredevil/
// carries 39 episodes of "Marvel's Daredevil" and 9 of "Daredevil: Born Again". Both groups
// emitted the same id, and a client keyed on id renders one and silently loses the other.
// That is how Star Trek: The Next Generation disappeared from a real Apple TV — a collision
// elsewhere in the list ate it, with nothing logged at any layer.
//
// Five folders in the live library are ambiguous this way, so this is not a hypothetical.

func TestSplitShowIDLeavesBareFolderIDsAlone(t *testing.T) {
	// Every id persisted before qualification existed is a bare folder name, and must keep
	// resolving exactly as it did — this is what stops the change breaking saved state.
	folder, group := splitShowID("Daredevil")
	if folder != "Daredevil" || group != "" {
		t.Fatalf("a bare id must pass through unchanged, got folder=%q group=%q", folder, group)
	}

	// Including folder names with characters that look structural but are not.
	for _, id := range []string{"NCIS", "Star Trek: The Next Generation", "X-Men - ANIME", "S.H.I.E.L.D."} {
		f, g := splitShowID(id)
		if f != id || g != "" {
			t.Errorf("splitShowID(%q) = (%q, %q), want the id unchanged with no qualifier", id, f, g)
		}
	}
}

func TestSplitShowIDSeparatesAQualifiedID(t *testing.T) {
	folder, group := splitShowID("Daredevil::daredevil: born again")
	if folder != "Daredevil" {
		t.Errorf("folder = %q, want %q", folder, "Daredevil")
	}
	if group != "daredevil: born again" {
		t.Errorf("group = %q, want %q", group, "daredevil: born again")
	}

	// The group key itself may contain a colon — splitting must use the FIRST separator
	// only, or a show named "X: Y" would lose part of its key.
	f, g := splitShowID("Folder::star trek: deep space nine")
	if f != "Folder" || g != "star trek: deep space nine" {
		t.Errorf("split on the first separator only: got (%q, %q)", f, g)
	}
}

// A bare id must produce NO extra predicate, so the common query stays byte-identical.
func TestShowGroupWhereIsEmptyForABareID(t *testing.T) {
	where, args := showGroupWhere("Daredevil")
	if where != "" || len(args) != 0 {
		t.Fatalf("a bare id must add no predicate, got where=%q args=%v", where, args)
	}
}

// A qualified id must narrow on show_name — the only thing that distinguishes two shows
// sharing a folder, since their paths cannot.
func TestShowGroupWhereNarrowsOnShowNameForAQualifiedID(t *testing.T) {
	where, args := showGroupWhere("Daredevil::daredevil: born again")
	if where == "" {
		t.Fatal("a qualified id must add a narrowing predicate")
	}
	if len(args) != 1 || args[0] != "daredevil: born again" {
		t.Fatalf("args = %v, want the group key alone", args)
	}
	// It must AND onto an existing folder predicate, never replace it: show_name is not
	// unique across the library, so matching on it alone would merge different shows.
	if len(where) < 5 || where[:5] != " AND " {
		t.Errorf("predicate must AND onto the folder match, got %q", where)
	}
}

// The round trip: an id emitted for an ambiguous folder must resolve back to that folder
// plus the group that produced it.
func TestQualifiedIDRoundTripsToItsFolderAndGroup(t *testing.T) {
	const folder = "Daredevil"
	const groupKey = "daredevil: born again"
	id := folder + showIDGroupSeparator + groupKey

	gotFolder, gotGroup := splitShowID(id)
	if gotFolder != folder || gotGroup != groupKey {
		t.Fatalf("round trip lost information: (%q, %q)", gotFolder, gotGroup)
	}

	where, args := showGroupWhere(id)
	if where == "" || args[0] != groupKey {
		t.Fatal("the resolved group key did not reach the query")
	}
}

// The separator must not appear in a real folder name, or a legitimate folder would be
// mis-split into a folder plus a bogus qualifier.
func TestSeparatorCannotBeConfusedWithARealFolderName(t *testing.T) {
	if showIDGroupSeparator != "::" {
		t.Fatalf("separator changed to %q — update this test and confirm it still cannot "+
			"appear in a folder name", showIDGroupSeparator)
	}
	// Every ambiguous folder in the live library, none of which contain the separator.
	for _, folder := range []string{
		"Daredevil", "Marvel's What If", "The Peripheral (2022)",
		"X-Men - ANIME Series and CARTOON Series", "Marvel's Agents of SHIELD",
	} {
		if f, g := splitShowID(folder); f != folder || g != "" {
			t.Errorf("real folder %q was mis-split into (%q, %q)", folder, f, g)
		}
	}
}
