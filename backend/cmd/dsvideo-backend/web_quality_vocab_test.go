package main

import (
	"regexp"
	"sort"
	"strings"
	"testing"
)

// TASK-1031: the web player's quality menu sent ?quality=1080 while the server only accepts
// 1080p (anything else silently means Auto), so choosing a quality changed nothing. These
// tests pin the page's vocabulary to the server's.

// pageQualityIDs returns the ids in the page's QUALITIES menu definition.
func pageQualityIDs(t *testing.T) []string {
	t.Helper()
	page := webPage(t)
	block := regexp.MustCompile(`(?s)const QUALITIES = \[(.*?)\];`).FindStringSubmatch(page)
	if block == nil {
		t.Fatal("web page has no QUALITIES menu definition")
	}
	var ids []string
	for _, m := range regexp.MustCompile(`id:\s*'([^']*)'`).FindAllStringSubmatch(block[1], -1) {
		ids = append(ids, m[1])
	}
	if len(ids) == 0 {
		t.Fatal("QUALITIES menu defines no ids")
	}
	return ids
}

func TestWebQualityMenuOffersOnlyValuesTheServerAccepts(t *testing.T) {
	for _, id := range pageQualityIDs(t) {
		if id == "auto" {
			continue // auto is sent as no parameter at all
		}
		if maxHeightForQuality(id) == 0 {
			t.Errorf("web menu offers quality %q but the server does not accept it (it would silently mean Auto)", id)
		}
	}
}

func TestWebQualityMenuOffersEveryValueTheServerAccepts(t *testing.T) {
	offered := map[string]bool{}
	for _, id := range pageQualityIDs(t) {
		offered[id] = true
	}
	var missing []string
	for q := range qualityHeights {
		if !offered[q] {
			missing = append(missing, q)
		}
	}
	sort.Strings(missing)
	if len(missing) > 0 {
		t.Errorf("server accepts quality %v but the web menu cannot send it", missing)
	}
}

func TestMaxHeightForQuality(t *testing.T) {
	cases := map[string]int{"1080p": 1080, "720p": 720, "480p": 480, "auto": 0, "": 0, "1080": 0, "4k": 0}
	for in, want := range cases {
		if got := maxHeightForQuality(in); got != want {
			t.Errorf("maxHeightForQuality(%q) = %d, want %d", in, got, want)
		}
	}
}

// The request is built from the menu id with no translation, so "the id is an accepted value"
// (above) is the same as "the request carries an accepted value". Pin the no-translation part.
func TestWebPlaybackRequestSendsMenuIDVerbatim(t *testing.T) {
	page := webPage(t)
	if !strings.Contains(page, "pbUrl += `&quality=${quality}`") {
		t.Error("playVideo no longer appends &quality=${quality} verbatim; if it now maps the menu id, update this test and keep the sent value in the server's accepted set")
	}
	if !strings.Contains(page, "onclick=\"selectQuality('${q.id}')\"") {
		t.Error("quality menu items no longer call selectQuality with the menu id")
	}
}
