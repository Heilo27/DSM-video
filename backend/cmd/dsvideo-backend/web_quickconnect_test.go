package main

// TASK-1049: the /web sign-in page's QuickConnect lookup says why it failed. It used to swallow
// every failure and quietly sign in against a guessed "<id>.quickconnect.to" (DSM's portal, not
// DSVideo, and unreachable from a browser: the server sends no CORS headers), so the user got a
// later "Failed to fetch" that named nothing. The page is one embedded file, so these are
// assertions on its source, in the style of web_button_states_test.go.

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// jsFunctionBody returns the text of `function <name>(` / `async function <name>(` through its
// closing brace at the same indent, or fails the test.
func jsFunctionBody(t *testing.T, page, name string) string {
	t.Helper()
	re := regexp.MustCompile(`(?m)^(\s*)(?:async )?function ` + regexp.QuoteMeta(name) + `\(`)
	loc := re.FindStringSubmatchIndex(page)
	if loc == nil {
		t.Fatalf("web/index.html has no function %s", name)
	}
	indent := page[loc[2]:loc[3]]
	rest := page[loc[0]:]
	end := strings.Index(rest, "\n"+indent+"}\n")
	if end < 0 {
		t.Fatalf("could not find the end of %s", name)
	}
	return rest[:end]
}

func TestWebQuickConnectNeverGuessesAHost(t *testing.T) {
	page := webPage(t)
	if strings.Contains(page, "}.quickconnect.to") {
		t.Error("the page builds a guessed <id>.quickconnect.to host; a failed lookup must be reported, not guessed around")
	}
	if strings.Contains(page, "Failed to resolve QuickConnect ID") {
		t.Error("the generic 'Failed to resolve QuickConnect ID' message is back; every failure names its cause")
	}
	body := jsFunctionBody(t, page, "resolveQuickConnect")
	if strings.Contains(body, "state.isEmbedded ? state.baseURL : ''") {
		t.Error("resolveQuickConnect skips the lookup when not embedded, which is the only mode that calls it")
	}
	if !strings.Contains(body, "/api/v1/auth/quickconnect/resolve") {
		t.Error("resolveQuickConnect no longer asks the server to resolve the ID")
	}
}

func TestWebQuickConnectNoCatchSwallowsAFailure(t *testing.T) {
	page := webPage(t)
	for _, fn := range []string{"resolveQuickConnect", "handleLogin"} {
		body := jsFunctionBody(t, page, fn)
		parts := strings.Split(body, "catch (")
		for i, after := range parts[1:] {
			window := after
			if len(window) > 400 {
				window = window[:400]
			}
			if !strings.Contains(window, "throw") && !strings.Contains(window, "errorDiv.textContent") {
				t.Errorf("%s: catch #%d neither rethrows nor shows the error:\n%s", fn, i+1, window)
			}
			if fn == "resolveQuickConnect" && !strings.Contains(window, "console.error") {
				t.Errorf("%s: catch #%d does not log what it caught:\n%s", fn, i+1, window)
			}
		}
	}
}

// Every error code the server's resolve endpoint can answer with has its own sentence on the
// page, so adding a code on the server without a sentence here fails this test.
func TestWebQuickConnectHasASentenceForEveryServerAnswer(t *testing.T) {
	page := webPage(t)
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	text := string(src)
	start := strings.Index(text, "func (s *Server) handleQuickConnectResolve(")
	if start < 0 {
		t.Fatal("handleQuickConnectResolve not found in main.go")
	}
	rest := text[start:]
	end := strings.Index(rest, "\n}\n")
	handler := rest[:end]
	codes := regexp.MustCompile(`writeErr\(w, [^,]+, "([a-z_]+)"\)`).FindAllStringSubmatch(handler, -1)
	if len(codes) == 0 {
		t.Fatal("found no error codes in handleQuickConnectResolve; the pattern is stale")
	}
	table := page[strings.Index(page, "const QC_PROBLEMS"):]
	table = table[:strings.Index(table, "};")]
	for _, c := range codes {
		if !strings.Contains(table, "      "+c[1]+":") {
			t.Errorf("the server answers %q but QC_PROBLEMS has no sentence for it", c[1])
		}
	}
	for _, key := range []string{"page_server_unreachable", "no_page_server", "no_address", "unexpected"} {
		if !strings.Contains(table, key+":") {
			t.Errorf("QC_PROBLEMS has no %q sentence", key)
		}
	}
	// Each sentence says what to do, not only what went wrong.
	for _, line := range strings.Split(table, "\n") {
		if strings.Contains(line, "=>") && !regexp.MustCompile(`(?i)try again|enter|check|open|reload`).MatchString(line) {
			t.Errorf("a QuickConnect message gives the user nothing to do: %s", strings.TrimSpace(line))
		}
	}
}

func TestWebQuickConnectSignInFailureNamesTheCause(t *testing.T) {
	body := jsFunctionBody(t, webPage(t), "handleLogin")
	if !strings.Contains(body, "viaQuickConnect") {
		t.Error("handleLogin does not tell a QuickConnect-resolved sign-in failure apart from any other")
	}
	if strings.Contains(body, "error.message") && !strings.Contains(body, "Couldn't reach ${server}") {
		t.Error("a network failure reaches the user as the browser's bare 'Failed to fetch'")
	}
}
