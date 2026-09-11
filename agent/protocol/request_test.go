package protocol

import (
	"bufio"
	"bytes"
	"errors"
	"strings"
	"testing"
)

func TestReadRequestAcceptsClosedRequestShapes(t *testing.T) {
	tests := []struct {
		line string
		want Request
	}{
		{`{"target":"port","port":65535}` + "\n", PortRequest{Port: 65535}},
		{`{"target":"shell","term":"xterm","cols":120,"rows":40,"command":null}` + "\n", ShellRequest{Term: "xterm", Cols: 120, Rows: 40}},
		{`{"target":"shell","term":"xterm","cols":120,"rows":40,"command":["sh","-c","true"]}` + "\n", ShellRequest{Term: "xterm", Cols: 120, Rows: 40, Command: []string{"sh", "-c", "true"}}},
	}

	for _, test := range tests {
		got, err := ReadRequest(NewReader(strings.NewReader(test.line)))
		if err != nil {
			t.Fatalf("ReadRequest(%q): %v", test.line, err)
		}
		if !requestsEqual(got, test.want) {
			t.Fatalf("ReadRequest(%q) = %#v, want %#v", test.line, got, test.want)
		}
	}
}

func TestReadRequestRejectsFieldAndValueMutations(t *testing.T) {
	invalid := []string{
		`{"target":"port"}`,
		`{"target":"port","port":80,"extra":true}`,
		`{"target":"port","port":0}`,
		`{"target":"port","port":65536}`,
		`{"target":"shell","term":"xterm","cols":120,"rows":40}`,
		`{"target":"shell","term":"xterm","cols":120,"rows":40,"command":null,"extra":true}`,
		`{"target":"shell","term":"","cols":120,"rows":40,"command":null}`,
		`{"target":"shell","term":"x\u0000term","cols":120,"rows":40,"command":null}`,
		`{"target":"shell","term":"xterm","cols":0,"rows":40,"command":null}`,
		`{"target":"shell","term":"xterm","cols":120,"rows":0,"command":null}`,
		`{"target":"shell","term":"xterm","cols":120,"rows":40,"command":[]}`,
		`{"target":"shell","term":"xterm","cols":120,"rows":40,"command":"sh"}`,
		`{"target":"shell","term":"xterm","cols":120,"rows":40,"command":["sh\u0000"]}`,
	}

	for _, line := range invalid {
		_, err := ReadRequest(NewReader(strings.NewReader(line + "\n")))
		if !errors.Is(err, ErrInvalidRequest) {
			t.Errorf("ReadRequest(%s) error = %v, want ErrInvalidRequest", line, err)
		}
	}
}

func TestReadRequestLineBound(t *testing.T) {
	prefix := `{"target":"port","port":80,"padding":"`
	suffix := `"}` + "\n"
	exact := prefix + strings.Repeat("x", LineLimit-len(prefix)-len(suffix)) + suffix
	over := prefix + strings.Repeat("x", LineLimit+1-len(prefix)-len(suffix)) + suffix

	if len(exact) != LineLimit || len(over) != LineLimit+1 {
		t.Fatal("invalid test line sizes")
	}
	if _, err := ReadRequest(NewReader(strings.NewReader(exact))); !errors.Is(err, ErrInvalidRequest) {
		t.Fatalf("exact-bound line error = %v, want ErrInvalidRequest for its extra field", err)
	}
	if _, err := ReadRequest(NewReader(strings.NewReader(over))); !errors.Is(err, bufio.ErrBufferFull) {
		t.Fatalf("over-bound line error = %v, want bufio.ErrBufferFull", err)
	}
}

func TestReplyEncodingsAreExact(t *testing.T) {
	tests := []struct {
		write func(*bytes.Buffer) error
		want  string
	}{
		{func(w *bytes.Buffer) error { return WriteAccepted(w) }, "{\"ok\":true}\n"},
		{func(w *bytes.Buffer) error { return WriteRejected(w, RejectionInvalidRequest) }, "{\"ok\":false,\"error\":\"invalid_request\"}\n"},
		{func(w *bytes.Buffer) error { return WriteRejected(w, RejectionConnectionRefused) }, "{\"ok\":false,\"error\":\"connection_refused\"}\n"},
	}

	for _, test := range tests {
		var got bytes.Buffer
		if err := test.write(&got); err != nil {
			t.Fatal(err)
		}
		if got.String() != test.want {
			t.Errorf("reply = %q, want %q", got.String(), test.want)
		}
	}
}

func FuzzReadRequest(f *testing.F) {
	f.Add([]byte(`{"target":"port","port":80}` + "\n"))
	f.Add([]byte(`{"target":"shell","term":"xterm","cols":80,"rows":24,"command":null}` + "\n"))
	f.Add([]byte{0, 1, 2, '\n'})
	f.Fuzz(func(t *testing.T, input []byte) {
		_, _ = ReadRequest(NewReader(bytes.NewReader(input)))
	})
}

func requestsEqual(left Request, right Request) bool {
	switch left := left.(type) {
	case PortRequest:
		right, ok := right.(PortRequest)
		return ok && left == right
	case ShellRequest:
		right, ok := right.(ShellRequest)
		return ok && left.Term == right.Term && left.Cols == right.Cols && left.Rows == right.Rows && slicesEqual(left.Command, right.Command)
	default:
		return false
	}
}

func slicesEqual(left []string, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}
