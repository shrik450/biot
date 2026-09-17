package input

import (
	"bytes"
	"testing"

	"github.com/shrik450/biot/cli/internal/api"
)

func TestStdinSecretPreservesEveryByteIncludingTrailingNewline(t *testing.T) {
	for _, value := range [][]byte{
		[]byte("alpha\n"),
		[]byte("alpha\nbeta\n"),
		[]byte("trailing space \n"),
		[]byte{0x00, 0x01, 0xfe, 0xff},
	} {
		got, err := StdinSecret(bytes.NewReader(value))
		if err != nil {
			t.Fatalf("StdinSecret(%q) returned error: %v", value, err)
		}
		if !bytes.Equal(got, value) {
			t.Errorf("StdinSecret(%q) = %q, changed the value", value, got)
		}
	}
}

func TestStdinSecretRejectsTooLargeValues(t *testing.T) {
	atLimit := bytes.Repeat([]byte("a"), maxSecretBytes)
	if _, err := StdinSecret(bytes.NewReader(atLimit)); err != nil {
		t.Fatalf("a value exactly at the limit should be accepted: %v", err)
	}
	overLimit := bytes.Repeat([]byte("a"), maxSecretBytes+1)
	if _, err := StdinSecret(bytes.NewReader(overLimit)); err == nil {
		t.Fatal("a value over the limit should be rejected")
	} else if err.Error() != api.FieldReasonMessage("value", "secret_value_too_large") {
		t.Fatalf("oversize error should reuse the shared vocabulary, got %v", err)
	}
}

func TestStdinTokenTrimsExactlyOneLineEnding(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"token\n", "token"},
		{"token\r\n", "token"},
		{"token", "token"},
		{"token\n\n", "token\n"},
		{"", ""},
		{"\n", ""},
	}
	for _, test := range tests {
		got, err := StdinToken(bytes.NewReader([]byte(test.input)))
		if err != nil {
			t.Fatalf("StdinToken(%q) returned error: %v", test.input, err)
		}
		if string(got) != test.want {
			t.Errorf("StdinToken(%q) = %q, want %q", test.input, got, test.want)
		}
	}
}

func TestLineReadsOneLineWithoutItsEnding(t *testing.T) {
	var prompt bytes.Buffer
	got, err := Line("Server URL: ", bytes.NewReader([]byte("http://127.0.0.1:4000\ntoken\n")), &prompt)
	if err != nil {
		t.Fatalf("Line returned error: %v", err)
	}
	if got != "http://127.0.0.1:4000" {
		t.Fatalf("Line = %q", got)
	}
	if prompt.String() != "Server URL: " {
		t.Fatalf("prompt = %q", prompt.String())
	}
}

func TestLineReturnsTheFinalLineWithoutANewline(t *testing.T) {
	got, err := Line("", bytes.NewReader([]byte("last")), &bytes.Buffer{})
	if err != nil {
		t.Fatalf("Line returned error: %v", err)
	}
	if got != "last" {
		t.Fatalf("Line = %q", got)
	}
}
