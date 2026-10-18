package main

import (
	"strings"
	"testing"
)

// TASK-952 / FRD-002 FR-203. The profile-name limit is counted in Unicode code points after
// trimming. The iOS and tvOS editor counts the same way (ProfileNameRules.swift) and pins the same
// literals in ProfileNameRulesTests; if you change a case here, change it there. Red if the server
// switched to bytes (an emoji name would fail early) or to grapheme clusters (the family emoji
// would count 1 and the 21-point name below would be accepted).
func TestValidProfileNameCountsCodePoints(t *testing.T) {
	const family = "\U0001F468‍\U0001F469‍\U0001F467‍\U0001F466" // 7 code points, 1 grapheme
	cases := []struct {
		label string
		raw   string
		want  bool
	}{
		{"20 ASCII", strings.Repeat("a", 20), true},
		{"21 ASCII", strings.Repeat("a", 21), false},
		{"empty", "", false},
		{"blank", "  \t\n ", false},
		{"padding is trimmed, not counted", "  " + strings.Repeat("a", 20) + "  ", true},
		{"family emoji costs seven: 21 points", "Grandma " + family + " Smith", false},
		{"family emoji costs seven: 20 points", "Grandma " + family + " Smit", true},
		{"decomposed e-acute is two points: 20", strings.Repeat("é", 10), true},
		{"decomposed e-acute is two points: 22", strings.Repeat("é", 11), false},
		{"precomposed e-acute is one point", strings.Repeat("é", 20), true},
		{"invalid UTF-8 is refused", "ab\xffcd", false},
	}
	for _, c := range cases {
		if _, ok := validProfileName(c.raw); ok != c.want {
			t.Errorf("%s: validProfileName(%q) ok = %v, want %v", c.label, c.raw, ok, c.want)
		}
	}
}
