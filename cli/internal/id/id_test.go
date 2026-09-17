package id

import (
	"regexp"
	"testing"
)

var uuidV4 = regexp.MustCompile(`\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z`)

func TestNewUsesTheCanonicalUUIDv4Shape(t *testing.T) {
	for range 64 {
		value, err := New()
		if err != nil {
			t.Fatalf("New returned error: %v", err)
		}
		if !uuidV4.MatchString(value) {
			t.Fatalf("New returned %q, which is not a canonical UUIDv4", value)
		}
	}
}

func TestNewIsUnique(t *testing.T) {
	seen := make(map[string]bool)
	for range 1024 {
		value, err := New()
		if err != nil {
			t.Fatalf("New returned error: %v", err)
		}
		if seen[value] {
			t.Fatalf("New repeated %q", value)
		}
		seen[value] = true
	}
}
