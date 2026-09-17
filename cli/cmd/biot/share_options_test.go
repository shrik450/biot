package main

import (
	"reflect"
	"strings"
	"testing"
)

func TestParseShareOptionsAccepted(t *testing.T) {
	tests := []struct {
		name      string
		arguments []string
		want      shareOptions
	}{
		{
			name:      "shell",
			arguments: []string{"demo", "--to", "person@example.test", "--shell"},
			want:      shareOptions{biot: "demo", email: "person@example.test", shell: true},
		},
		{
			name:      "port",
			arguments: []string{"demo", "--to", "person@example.test", "--port", "3000"},
			want:      shareOptions{biot: "demo", email: "person@example.test", port: 3000},
		},
		{
			name:      "options before the position",
			arguments: []string{"demo", "--port", "443", "--to", "person@example.test"},
			want:      shareOptions{biot: "demo", email: "person@example.test", port: 443},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := parseShareOptions("share", test.arguments)
			if err != nil {
				t.Fatalf("parseShareOptions returned error: %v", err)
			}
			if !reflect.DeepEqual(got, test.want) {
				t.Fatalf("parseShareOptions = %#v, want %#v", got, test.want)
			}
		})
	}
}

func TestParseShareOptionsRejected(t *testing.T) {
	tests := []struct {
		name      string
		arguments []string
		want      string
	}{
		{name: "no arguments", arguments: nil, want: "expects a Biot"},
		{name: "missing email", arguments: []string{"demo", "--shell"}, want: "--to"},
		{name: "missing share kind", arguments: []string{"demo", "--to", "a@b.test"}, want: "--shell or --port"},
		{name: "both kinds", arguments: []string{"demo", "--to", "a@b.test", "--shell", "--port", "80"}, want: "either"},
		{name: "bad port", arguments: []string{"demo", "--to", "a@b.test", "--port", "0"}, want: "1 to 65535"},
		{name: "duplicate email", arguments: []string{"demo", "--to", "a@b.test", "--to", "c@d.test", "--shell"}, want: "once"},
		{name: "duplicate shell", arguments: []string{"demo", "--to", "a@b.test", "--shell", "--shell"}, want: "once"},
		{name: "empty email", arguments: []string{"demo", "--to", "", "--shell"}, want: "--to"},
		{name: "unknown option", arguments: []string{"demo", "--mystery"}, want: "--mystery"},
		{name: "dangling port", arguments: []string{"demo", "--to", "a@b.test", "--port"}, want: "port after --port"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := parseShareOptions("share", test.arguments)
			if err == nil {
				t.Fatal("expected an error")
			}
			if !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error %q does not contain %q", err, test.want)
			}
		})
	}
}

func TestShareDescriptionNamesPortOrShell(t *testing.T) {
	if got := shareDescription("view access", shareOptions{shell: true}); got != "Shell access" {
		t.Fatalf("shell description = %q", got)
	}
	if got := shareDescription("view access", shareOptions{port: 8080}); got != "View access on port 8080" {
		t.Fatalf("port description = %q", got)
	}
}
