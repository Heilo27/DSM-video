package main

// TASK-1000 / TASK-959 AC4 (FRD-001 FR-148): the /web player carries the apps' brand red,
// #D1262F. The colour has ONE home in the page, the --brand-red custom property; the accent
// tokens and every gradient derive from it, so the colour cannot drift by theme.

import (
	"regexp"
	"strings"
	"testing"
)

func TestWebAccentIsTheBrandRedFromOneProperty(t *testing.T) {
	css := webPage(t)

	// The brand colour is written exactly once, as the --brand-red definition.
	if n := strings.Count(strings.ToLower(css), "#d1262f"); n != 1 {
		t.Errorf("#D1262F appears %d times, want exactly 1 (the --brand-red definition)", n)
	}
	if !regexp.MustCompile(`(?i)--brand-red:\s*#d1262f\s*;`).MatchString(css) {
		t.Error("no `--brand-red: #D1262F;` definition")
	}

	// The old blue accent is gone from both themes, hex and rgba forms.
	for _, blue := range []string{"#4a9eff", "#5eabff", "#0071e3", "#0077ed", "74, 158, 255", "0, 113, 227"} {
		if strings.Contains(strings.ToLower(css), blue) {
			t.Errorf("old blue accent %q still in the page", blue)
		}
	}

	// Each accent token derives from --brand-red, in every place it is defined (dark + light).
	for _, tok := range []string{"--accent", "--accent-hover", "--accent-bg"} {
		re := regexp.MustCompile(`(?m)^\s*` + regexp.QuoteMeta(tok) + `:\s*([^;]+);`)
		defs := re.FindAllStringSubmatch(css, -1)
		if len(defs) == 0 {
			t.Errorf("%s is not defined", tok)
		}
		for _, d := range defs {
			if !strings.Contains(d[1], "var(--brand-red)") {
				t.Errorf("%s: %q does not derive from var(--brand-red)", tok, strings.TrimSpace(d[1]))
			}
		}
	}

	// The gradients take the accent, not a second hardcoded hue.
	if strings.Contains(strings.ToLower(css), "#a855f7") {
		t.Error("a hardcoded purple (#a855f7) gradient stop is still in the page")
	}
}
