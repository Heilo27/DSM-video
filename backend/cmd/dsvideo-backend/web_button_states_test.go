package main

// TASK-959 (S2: every control works and can be reached): the /web player's buttons render
// pressed (:active), keyboard-focused (:focus-visible) and disabled the same way, there is one
// primary-button style, and the login error tint follows the theme's --danger. The page is one
// embedded file, so these are assertions on that file's CSS and markup.

import (
	"regexp"
	"strings"
	"testing"
)

var webButtonFamily = []string{
	".btn", ".btn-close", ".player-menu-btn", ".btn-next-episode", ".filter-pill", ".sidebar-item",
}

func webPage(t *testing.T) string {
	t.Helper()
	b, err := webContent.ReadFile("web/index.html")
	if err != nil {
		t.Fatalf("embedded web/index.html: %v", err)
	}
	return string(b)
}

// cssBlock returns the declaration body of the first rule whose selector list is exactly sel
// (a single selector, no commas), or "" when there is none.
func cssBlock(css, sel string) string {
	re := regexp.MustCompile(`(?m)^\s*` + regexp.QuoteMeta(sel) + `\s*\{([^}]*)\}`)
	m := re.FindStringSubmatch(css)
	if m == nil {
		return ""
	}
	return m[1]
}

func TestWebButtonFamilySharesPressedFocusAndDisabledStates(t *testing.T) {
	css := webPage(t)
	for _, state := range []string{":focus-visible", ":active:not(:disabled)", ":disabled"} {
		// The state selector must appear in a selector list for every member of the family.
		for _, cls := range webButtonFamily {
			want := cls + state
			re := regexp.MustCompile(`(?m)^\s*` + regexp.QuoteMeta(want) + `\s*[,{]`)
			if !re.MatchString(css) {
				t.Errorf("no %q rule: %s has no shared %s style", want, cls, strings.TrimSuffix(state, ":not(:disabled)"))
			}
		}
	}
	if b := cssBlock(css, ".sidebar-item:disabled"); !strings.Contains(b, "cursor: not-allowed") {
		t.Errorf("the shared :disabled rule must show a not-allowed cursor, got %q", b)
	}
	if b := cssBlock(css, ".sidebar-item:focus-visible"); !strings.Contains(b, "outline") {
		t.Errorf("the shared :focus-visible rule must draw an outline, got %q", b)
	}
	if b := cssBlock(css, ".sidebar-item:active:not(:disabled)"); !strings.Contains(b, "transform") {
		t.Errorf("the shared :active rule must change the pressed look, got %q", b)
	}
	// One home: .btn-primary must not carry its own private :disabled rule any more.
	if regexp.MustCompile(`(?m)^\s*\.btn-primary:disabled`).MatchString(css) {
		t.Errorf(".btn-primary:disabled is a second copy of the shared :disabled rule")
	}
}

func TestPlayButtonComposesPrimaryButton(t *testing.T) {
	css := webPage(t)
	if !strings.Contains(css, `class="btn btn-primary btn-play"`) {
		t.Errorf("the Play button markup must compose .btn .btn-primary, not stand alone")
	}
	if strings.Contains(css, `class="btn-play"`) {
		t.Errorf("a Play button still uses .btn-play alone")
	}
	body := cssBlock(css, ".btn-play")
	if body == "" {
		t.Fatalf(".btn-play rule not found")
	}
	for _, own := range []string{"background", "color:", "border", "cursor", "transition", "border-radius"} {
		if strings.Contains(body, own) {
			t.Errorf(".btn-play re-declares %q, which .btn/.btn-primary already own", own)
		}
	}
}

func TestLoginErrorTintFollowsTheThemeDanger(t *testing.T) {
	css := webPage(t)
	body := cssBlock(css, ".login-error")
	if body == "" {
		t.Fatalf(".login-error rule not found")
	}
	bg := regexp.MustCompile(`background:\s*([^;]+);`).FindStringSubmatch(body)
	if bg == nil {
		t.Fatalf(".login-error has no background: %q", body)
	}
	if !strings.Contains(bg[1], "var(--danger)") {
		t.Errorf(".login-error background %q is not derived from var(--danger); it will not follow the light theme", bg[1])
	}
	if regexp.MustCompile(`rgba?\(\s*255\s*,\s*71\s*,\s*87`).MatchString(bg[1]) {
		t.Errorf(".login-error background hardcodes the dark theme's danger colour: %q", bg[1])
	}
}
