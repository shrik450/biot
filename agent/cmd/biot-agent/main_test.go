package main

import (
	"bufio"
	"bytes"
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"syscall"
	"testing"
	"time"
)

var agentBinary string

func TestMain(m *testing.M) {
	directory, err := os.MkdirTemp("", "biot-agent-test-")
	if err != nil {
		panic(err)
	}
	agentBinary = filepath.Join(directory, "biot-agent")
	command := exec.Command("go", "build", "-o", agentBinary, ".")
	if output, err := command.CombinedOutput(); err != nil {
		panic(string(output))
	}
	status := m.Run()
	_ = os.RemoveAll(directory)
	os.Exit(status)
}

func TestAgentReplacesStaleSocketAndServesPortTargets(t *testing.T) {
	directory := shortTempDir(t)
	socket := filepath.Join(directory, "agent.sock")
	if err := os.WriteFile(socket, []byte("stale"), 0o600); err != nil {
		t.Fatal(err)
	}
	command := startAgent(t, socket)
	defer stopAgent(command)

	info, err := os.Stat(socket)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o666 || info.Mode()&os.ModeSocket == 0 {
		t.Fatalf("socket mode = %v", info.Mode())
	}

	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	serviceDone := make(chan error, 1)
	go func() {
		connection, acceptErr := listener.Accept()
		if acceptErr != nil {
			serviceDone <- acceptErr
			return
		}
		defer connection.Close()
		buffer := make([]byte, 4)
		if _, err := io.ReadFull(connection, buffer); err != nil {
			serviceDone <- err
			return
		}
		_, err = connection.Write(bytes.ToUpper(buffer))
		serviceDone <- err
	}()

	port := listener.Addr().(*net.TCPAddr).Port
	connection := dialAgent(t, socket)
	if _, err := connection.Write([]byte(`{"target":"port","port":` + strconv.Itoa(port) + `}` + "\n")); err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(connection)
	line, err := reader.ReadString('\n')
	if err != nil || line != "{\"ok\":true}\n" {
		t.Fatalf("accepted reply = %q, %v", line, err)
	}
	if _, err := connection.Write([]byte("ping")); err != nil {
		t.Fatal(err)
	}
	reply := make([]byte, 4)
	if _, err := io.ReadFull(reader, reply); err != nil || string(reply) != "PING" {
		t.Fatalf("relayed reply = %q, %v", reply, err)
	}
	connection.Close()
	if err := <-serviceDone; err != nil {
		t.Fatal(err)
	}

	closed := reserveClosedPort(t)
	connection = dialAgent(t, socket)
	defer connection.Close()
	if _, err := connection.Write([]byte(`{"target":"port","port":` + strconv.Itoa(closed) + `}` + "\n")); err != nil {
		t.Fatal(err)
	}
	line, err = bufio.NewReader(connection).ReadString('\n')
	if err != nil || line != "{\"ok\":false,\"error\":\"connection_refused\"}\n" {
		t.Fatalf("refused reply = %q, %v", line, err)
	}
}

func TestAgentRejectsMalformedAndOversizedRequests(t *testing.T) {
	socket := filepath.Join(shortTempDir(t), "agent.sock")
	command := startAgent(t, socket)
	defer stopAgent(command)

	for _, request := range []string{"not json\n", `{"target":"unknown"}` + "\n"} {
		connection := dialAgent(t, socket)
		if _, err := connection.Write([]byte(request)); err != nil {
			t.Fatal(err)
		}
		line, err := bufio.NewReader(connection).ReadString('\n')
		connection.Close()
		if err != nil || line != "{\"ok\":false,\"error\":\"invalid_request\"}\n" {
			t.Fatalf("rejection = %q, %v", line, err)
		}
	}

	connection := dialAgent(t, socket)
	_, _ = connection.Write(bytes.Repeat([]byte("x"), 16*1024+1))
	_ = connection.CloseWrite()
	_ = connection.SetReadDeadline(time.Now().Add(time.Second))
	data, err := io.ReadAll(connection)
	connection.Close()
	if err != nil && !errors.Is(err, syscall.ECONNRESET) || len(data) != 0 {
		t.Fatalf("oversized request response = %q, %v", data, err)
	}
}

func TestAgentRequiresSocketAndShellEntrypoint(t *testing.T) {
	tests := [][]string{
		{},
		{"--socket", filepath.Join(shortTempDir(t), "agent.sock")},
		{"--shell-entrypoint", "/bin/sh"},
	}
	for _, arguments := range tests {
		command := exec.Command(agentBinary, arguments...)
		if err := command.Run(); err == nil {
			t.Fatalf("biot-agent %v exited successfully", arguments)
		}
	}
}

func startAgent(t *testing.T, socket string) *exec.Cmd {
	t.Helper()
	entrypoint := filepath.Join(t.TempDir(), "shell-entry")
	if err := os.WriteFile(entrypoint, []byte("#!/bin/sh\nexec \"$@\"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	command := exec.Command(agentBinary, "--socket", socket, "--shell-entrypoint", entrypoint)
	command.Stdout = io.Discard
	command.Stderr = io.Discard
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		info, err := os.Stat(socket)
		if err == nil && info.Mode()&os.ModeSocket != 0 {
			return command
		}
		if command.ProcessState != nil {
			t.Fatalf("agent exited before creating its socket")
		}
		time.Sleep(10 * time.Millisecond)
	}
	stopAgent(command)
	t.Fatalf("agent did not create %s", socket)
	return nil
}

func stopAgent(command *exec.Cmd) {
	if command == nil || command.Process == nil {
		return
	}
	_ = command.Process.Kill()
	_ = command.Wait()
}

func dialAgent(t *testing.T, socket string) *net.UnixConn {
	t.Helper()
	connection, err := net.DialUnix("unix", nil, &net.UnixAddr{Name: socket, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	return connection
}

func reserveClosedPort(t *testing.T) int {
	t.Helper()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	return port
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
