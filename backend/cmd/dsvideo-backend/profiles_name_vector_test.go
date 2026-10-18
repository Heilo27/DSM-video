package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// TASK-1023 / FRD-002 FR-203. The profile-name trim and length rule is checked against ONE shared
// vector, docs/test-vectors/profile-name.json, which the iOS/tvOS client asserts too
// (ProfileNameVectorTests.swift). strings.TrimSpace trims unicode.IsSpace; Foundation's
// whitespacesAndNewlines is a different set (it also trims U+200B), so the client trims an explicit
// copy of Go's set. Add a case to the vector, never to one side only.
func TestValidProfileNameMatchesSharedVector(t *testing.T) {
	path := filepath.Join("..", "..", "..", "docs", "test-vectors", "profile-name.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read shared vector %s: %v", path, err)
	}
	var vector struct {
		MaxLength int `json:"maxLength"`
		Cases     []struct {
			Label   string `json:"label"`
			Raw     string `json:"raw"`
			Trimmed string `json:"trimmed"`
			Valid   bool   `json:"valid"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(data, &vector); err != nil {
		t.Fatalf("decode shared vector: %v", err)
	}
	if vector.MaxLength != maxProfileNameRunes {
		t.Errorf("vector maxLength = %d, backend maxProfileNameRunes = %d", vector.MaxLength, maxProfileNameRunes)
	}
	if len(vector.Cases) == 0 {
		t.Fatal("shared vector has no cases")
	}
	for _, c := range vector.Cases {
		name, ok := validProfileName(c.Raw)
		if name != c.Trimmed {
			t.Errorf("%s: trimmed %q, vector says %q", c.Label, name, c.Trimmed)
		}
		if ok != c.Valid {
			t.Errorf("%s: valid = %v, vector says %v", c.Label, ok, c.Valid)
		}
	}
}
