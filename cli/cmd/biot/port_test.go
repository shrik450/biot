package main

import (
	"strings"
	"testing"
)

func TestParsePortAccepted(t *testing.T) {
	for _, value := range []string{"1", "80", "443", "65535"} {
		port, err := parsePort(value, "publish")
		if err != nil {
			t.Errorf("parsePort(%q) returned error: %v", value, err)
		}
		if port == 0 {
			t.Errorf("parsePort(%q) returned zero", value)
		}
	}
}

func TestParsePortRejected(t *testing.T) {
	for _, value := range []string{"0", "-1", "65536", "abc", "", "1.5"} {
		if _, err := parsePort(value, "publish"); err == nil {
			t.Errorf("parsePort(%q) should be rejected", value)
		}
	}
}

func TestParsePortErrorIsActionable(t *testing.T) {
	_, err := parsePort("99999", "publish")
	if err == nil {
		t.Fatal("expected an error")
	}
	if !strings.Contains(err.Error(), "1 to 65535") {
		t.Fatalf("port error should name the allowed range: %v", err)
	}
}
