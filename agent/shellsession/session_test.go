package shellsession

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"biot/agent/protocol"
)

func TestRunSendsOutputBeforeExitStatus(t *testing.T) {
	client, result := startSession(t, protocol.ShellRequest{
		Term: "xterm", Cols: 80, Rows: 24,
		Command: []string{"/bin/sh", "-c", "printf output; exit 7"},
	})
	defer client.Close()

	var output bytes.Buffer
	for {
		frame := readFrame(t, client)
		switch frame.Type {
		case protocol.FrameData:
			output.Write(frame.Payload)
		case protocol.FrameExit:
			if !bytes.Equal(frame.Payload, []byte{7}) {
				t.Fatalf("exit payload = %v", frame.Payload)
			}
			if !strings.Contains(output.String(), "output") {
				t.Fatalf("exit arrived before output: %q", output.String())
			}
			if err := <-result; err != nil {
				t.Fatal(err)
			}
			return
		default:
			t.Fatalf("unexpected frame type %d", frame.Type)
		}
	}
}

func TestRunAppliesResizeFrames(t *testing.T) {
	client, result := startSession(t, protocol.ShellRequest{
		Term: "xterm", Cols: 80, Rows: 24,
		Command: []string{"/bin/sh", "-c", "stty size; read value; stty size"},
	})
	defer client.Close()

	before := readUntil(t, client, "24 80")
	resize := []byte{0, 100, 0, 40}
	if err := protocol.WriteFrame(client, protocol.FrameResize, resize); err != nil {
		t.Fatal(err)
	}
	if err := protocol.WriteFrame(client, protocol.FrameData, []byte("continue\n")); err != nil {
		t.Fatal(err)
	}
	after := readUntil(t, client, "40 100")
	if !strings.Contains(before, "24 80") || !strings.Contains(after, "40 100") {
		t.Fatalf("terminal sizes before=%q after=%q", before, after)
	}
	for {
		frame := readFrame(t, client)
		if frame.Type == protocol.FrameExit {
			break
		}
	}
	if err := <-result; err != nil {
		t.Fatal(err)
	}
}

func TestRunClosesAndEndsChildOnInvalidPeerFrames(t *testing.T) {
	tests := []struct {
		name string
		send func(*testing.T, *net.UnixConn)
	}{
		{"invalid resize length", func(t *testing.T, connection *net.UnixConn) {
			writeFrame(t, connection, protocol.FrameResize, []byte{0, 80})
		}},
		{"zero resize", func(t *testing.T, connection *net.UnixConn) {
			writeFrame(t, connection, protocol.FrameResize, []byte{0, 0, 0, 24})
		}},
		{"unknown type", func(t *testing.T, connection *net.UnixConn) {
			writeFrame(t, connection, 99, nil)
		}},
		{"wrong direction exit", func(t *testing.T, connection *net.UnixConn) {
			writeFrame(t, connection, protocol.FrameExit, []byte{0})
		}},
		{"oversized frame", func(t *testing.T, connection *net.UnixConn) {
			header := []byte{protocol.FrameData, 0, 1, 0, 1}
			if _, err := connection.Write(header); err != nil {
				t.Fatal(err)
			}
		}},
		{"truncated frame", func(t *testing.T, connection *net.UnixConn) {
			header := []byte{protocol.FrameData, 0, 0, 0, 4, 1}
			if _, err := connection.Write(header); err != nil {
				t.Fatal(err)
			}
			if err := connection.CloseWrite(); err != nil {
				t.Fatal(err)
			}
		}},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			pidFile := filepath.Join(t.TempDir(), "pid")
			command := fmt.Sprintf("echo $$ > %q; while :; do sleep 1; done", pidFile)
			client, result := startSession(t, protocol.ShellRequest{
				Term: "xterm", Cols: 80, Rows: 24,
				Command: []string{"/bin/sh", "-c", command},
			})
			pid := waitForPID(t, pidFile)
			t.Cleanup(func() { _ = syscall.Kill(-pid, syscall.SIGKILL) })
			test.send(t, client)
			if err := <-result; !errors.Is(err, ErrPeer) {
				t.Fatalf("Run error = %v, want ErrPeer", err)
			}
			client.Close()
			waitForProcessGone(t, pid, DisconnectGrace+time.Second)
		})
	}
}

func TestRunKillsAChildThatIgnoresHangupAfterPeerClose(t *testing.T) {
	pidFile := filepath.Join(t.TempDir(), "pid")
	command := fmt.Sprintf("trap '' HUP; echo $$ > %q; while :; do sleep 1; done", pidFile)
	client, result := startSession(t, protocol.ShellRequest{
		Term: "xterm", Cols: 80, Rows: 24,
		Command: []string{"/bin/sh", "-c", command},
	})
	pid := waitForPID(t, pidFile)
	t.Cleanup(func() { _ = syscall.Kill(-pid, syscall.SIGKILL) })
	started := time.Now()
	client.Close()
	if err := <-result; !errors.Is(err, ErrPeer) {
		t.Fatalf("Run error = %v, want ErrPeer", err)
	}
	waitForProcessGone(t, pid, DisconnectGrace+time.Second)
	if time.Since(started) < DisconnectGrace {
		t.Fatalf("child ignoring SIGHUP ended before the %s grace", DisconnectGrace)
	}
}

func startSession(t *testing.T, request protocol.ShellRequest) (*net.UnixConn, <-chan error) {
	t.Helper()
	directory := shortTempDir(t)
	entrypoint := filepath.Join(directory, "shell-entry")
	script := "#!/bin/sh\nif [ \"$#\" -gt 0 ]; then exec \"$@\"; fi\nexec /bin/sh\n"
	if err := os.WriteFile(entrypoint, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	server, client := unixPair(t)
	result := make(chan error, 1)
	go func() {
		defer server.Close()
		result <- Run(server, protocol.NewReader(server), entrypoint, request)
	}()
	return client, result
}

func unixPair(t *testing.T) (*net.UnixConn, *net.UnixConn) {
	t.Helper()
	path := filepath.Join(shortTempDir(t), "session.sock")
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	accepted := make(chan *net.UnixConn, 1)
	go func() {
		connection, acceptErr := listener.AcceptUnix()
		if acceptErr == nil {
			accepted <- connection
		}
	}()
	client, err := net.DialUnix("unix", nil, &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	return <-accepted, client
}

func shortTempDir(t *testing.T) string {
	t.Helper()
	directory, err := os.MkdirTemp(".", ".biot-agent-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(directory) })
	return directory
}

func readUntil(t *testing.T, connection *net.UnixConn, wanted string) string {
	t.Helper()
	var output bytes.Buffer
	for !strings.Contains(output.String(), wanted) {
		frame := readFrame(t, connection)
		if frame.Type != protocol.FrameData {
			t.Fatalf("frame type = %d before %q", frame.Type, wanted)
		}
		output.Write(frame.Payload)
	}
	return output.String()
}

func readFrame(t *testing.T, connection *net.UnixConn) protocol.Frame {
	t.Helper()
	if err := connection.SetReadDeadline(time.Now().Add(3 * time.Second)); err != nil {
		t.Fatal(err)
	}
	frame, err := protocol.ReadFrame(connection)
	if err != nil {
		t.Fatal(err)
	}
	return frame
}

func writeFrame(t *testing.T, connection *net.UnixConn, frameType byte, payload []byte) {
	t.Helper()
	if err := protocol.WriteFrame(connection, frameType, payload); err != nil {
		t.Fatal(err)
	}
}

func waitForPID(t *testing.T, path string) int {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		content, err := os.ReadFile(path)
		if err == nil {
			var pid int
			if _, err := fmt.Sscanf(string(content), "%d", &pid); err == nil {
				return pid
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("PID file %s was not written", path)
	return 0
}

func waitForProcessGone(t *testing.T, pid int, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if err := syscall.Kill(pid, 0); errors.Is(err, syscall.ESRCH) {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("process %d remained alive", pid)
}

func frameHeader(frameType byte, length uint32) []byte {
	header := make([]byte, 5)
	header[0] = frameType
	binary.BigEndian.PutUint32(header[1:], length)
	return header
}
