package main

import (
	"reflect"
	"strings"
	"testing"
)

func TestParseCreateOptionsAccepted(t *testing.T) {
	tests := []struct {
		name      string
		arguments []string
		want      createOptions
	}{
		{
			name:      "required only",
			arguments: []string{"--repo", "https://example.test/r.git", "--name", "demo"},
			want:      createOptions{repository: "https://example.test/r.git", name: "demo"},
		},
		{
			name: "every repeatable option",
			arguments: []string{
				"--repo", "https://example.test/r.git", "--name", "demo", "--node", "node-1",
				"--layer", "a", "--layer", "b",
				"--secret", "TOKEN", "--fetch-credential", "https://git.test/x.git",
			},
			want: createOptions{
				repository: "https://example.test/r.git", name: "demo", node: "node-1",
				layers: []string{"a", "b"}, secretNames: []string{"TOKEN"},
				fetchCredentials: []string{"https://git.test/x.git"},
			},
		},
		{
			name:      "stdin with one secret",
			arguments: []string{"--repo", "r", "--name", "n", "--secret", "A", "--stdin"},
			want:      createOptions{repository: "r", name: "n", secretNames: []string{"A"}, stdin: true},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := parseCreateOptions(test.arguments)
			if err != nil {
				t.Fatalf("parseCreateOptions returned error: %v", err)
			}
			if !reflect.DeepEqual(got, test.want) {
				t.Fatalf("parseCreateOptions = %#v, want %#v", got, test.want)
			}
		})
	}
}

func TestParseCreateOptionsRejected(t *testing.T) {
	tests := []struct {
		name      string
		arguments []string
		want      string
	}{
		{name: "missing repo and name", arguments: nil, want: "--repo and --name"},
		{name: "missing name", arguments: []string{"--repo", "r"}, want: "--repo and --name"},
		{name: "unknown option", arguments: []string{"--repo", "r", "--name", "n", "--mystery", "x"}, want: "--mystery"},
		{name: "dangling option", arguments: []string{"--repo", "r", "--name"}, want: "incomplete"},
		{name: "stdin with no credential", arguments: []string{"--repo", "r", "--name", "n", "--stdin"}, want: "exactly one"},
		{name: "stdin with two secrets", arguments: []string{"--repo", "r", "--name", "n", "--secret", "A", "--secret", "B", "--stdin"}, want: "exactly one"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := parseCreateOptions(test.arguments)
			if err == nil {
				t.Fatal("expected an error")
			}
			if !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error %q does not contain %q", err, test.want)
			}
		})
	}
}

func TestParseCreateOptionsLeavesNilLayerSlice(t *testing.T) {
	// runCreate substitutes an empty slice before encoding. This test pins the
	// parser's contract so the substitution stays deliberate.
	options, err := parseCreateOptions([]string{"--repo", "r", "--name", "n"})
	if err != nil {
		t.Fatalf("parseCreateOptions returned error: %v", err)
	}
	if options.layers != nil {
		t.Fatalf("layers should start nil, got %#v", options.layers)
	}
}
