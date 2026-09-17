package main

import (
	"strings"
	"testing"
)

func TestParseValueCommandAccepted(t *testing.T) {
	tests := []struct {
		name      string
		arguments []string
		wantRef   string
		wantName  string
		wantStdin bool
	}{
		{name: "hidden prompt by default", arguments: []string{"demo", "TOKEN"}},
		{name: "stdin flag", arguments: []string{"demo", "TOKEN", "--stdin"}, wantStdin: true},
		{name: "stdin flag first", arguments: []string{"--stdin", "demo", "TOKEN"}, wantStdin: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			reference, valueName, stdin, err := parseValueCommand("secret set", test.arguments)
			if err != nil {
				t.Fatalf("parseValueCommand returned error: %v", err)
			}
			if reference != "demo" || valueName != "TOKEN" {
				t.Fatalf("parseValueCommand = (%q, %q), want (demo, TOKEN)", reference, valueName)
			}
			if stdin != test.wantStdin {
				t.Fatalf("stdin = %v, want %v", stdin, test.wantStdin)
			}
		})
	}
}

func TestParseValueCommandRejected(t *testing.T) {
	tests := []struct {
		name      string
		arguments []string
		want      string
	}{
		{name: "no arguments", arguments: nil, want: "expects a Biot"},
		{name: "one argument", arguments: []string{"demo"}, want: "expects a Biot"},
		{name: "three positionals", arguments: []string{"demo", "A", "B"}, want: "expects a Biot"},
		{name: "duplicate stdin", arguments: []string{"demo", "A", "--stdin", "--stdin"}, want: "only once"},
		{name: "unknown option", arguments: []string{"demo", "A", "--mystery"}, want: "--mystery"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, _, _, err := parseValueCommand("secret set", test.arguments)
			if err == nil {
				t.Fatal("expected an error")
			}
			if !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error %q does not contain %q", err, test.want)
			}
		})
	}
}
