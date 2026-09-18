//go:build e2e

// Package e2e drives the real biot binary against a real Biot server. It is
// behind the e2e build tag because it needs a running Phoenix server, a bearer
// token, and a Biot the token can read. See README.md in this directory.
package e2e

import (
	"bytes"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

var cliBinary string

func TestMain(m *testing.M) {
	directory, err := os.MkdirTemp("", "biot-e2e-bin")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	cliBinary = filepath.Join(directory, "biot")
	if override := os.Getenv("BIOT_E2E_BINARY"); override != "" {
		cliBinary = override
	} else {
		build := exec.Command("go", "build", "-o", cliBinary, "./cmd/biot")
		build.Dir = ".."
		build.Env = append(os.Environ(), "GOCACHE=/tmp/biot-go-cache")
		if output, err := build.CombinedOutput(); err != nil {
			fmt.Fprintf(os.Stderr, "building the CLI failed: %v\n%s", err, output)
			os.RemoveAll(directory)
			os.Exit(1)
		}
	}
	code := m.Run()
	os.RemoveAll(directory)
	os.Exit(code)
}

func requireEnv(t *testing.T, key string) string {
	t.Helper()
	value := os.Getenv(key)
	if value == "" {
		t.Fatalf("%s must be set to run the e2e suite", key)
	}
	return value
}

func serverURL(t *testing.T) string {
	t.Helper()
	if value := os.Getenv("BIOT_E2E_SERVER"); value != "" {
		return value
	}
	return "http://localhost:4000"
}

func requireNode(t *testing.T) string {
	t.Helper()
	return requireEnv(t, "BIOT_E2E_NODE")
}

// stateTimeout bounds a wait for a state the node reports. The create flow already waits up to
// 90s for its own markers, and a report arrives when the node's connection next sweeps, so this is
// generous for a loaded machine rather than tuned to a quiet one.
const stateTimeout = 90 * time.Second

// statePollInterval is short enough to notice a report that lands immediately, and long enough
// that polling does not swamp a loaded machine.
const statePollInterval = 100 * time.Millisecond

// waitForShow polls `biot show NAME` until its output contains want, and returns that output.
//
// A Biot's container and data state are what the node reports, so a command that changes them
// returns as soon as the server records the intent. Asserting that state once is a race. The
// failure prints what it last saw and what it wanted, so the next person does not have to rerun
// the suite to find out.
func waitForShow(t *testing.T, env *cliEnv, name string, want string) string {
	t.Helper()
	deadline := time.Now().Add(stateTimeout)

	for {
		show := env.run(t, nil, "show", name)
		if show.exit != 0 {
			t.Fatalf("show %s exited %d while waiting for %q:\n%s", name, show.exit, want, show.combined())
		}
		if strings.Contains(show.stdout, want) {
			return show.stdout
		}
		if time.Now().After(deadline) {
			t.Fatalf("show %s did not report %q within %s; the last output was:\n%s", name, want, stateTimeout, show.stdout)
		}
		time.Sleep(statePollInterval)
	}
}

type cliEnv struct {
	configHome string
	home       string
	temp       string
	extra      []string
}

func newCLIEnv(t *testing.T) *cliEnv {
	t.Helper()
	root := t.TempDir()
	env := &cliEnv{
		configHome: filepath.Join(root, "config"),
		home:       filepath.Join(root, "home"),
		temp:       filepath.Join(root, "tmp"),
	}
	for _, directory := range []string{env.configHome, env.home, env.temp} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			t.Fatalf("create %s: %v", directory, err)
		}
	}
	return env
}

func (e *cliEnv) writeConfig(t *testing.T, server string, token string) {
	t.Helper()
	directory := filepath.Join(e.configHome, "biot")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatalf("create config directory: %v", err)
	}
	contents, err := json.Marshal(map[string]string{"server_url": server, "token": token})
	if err != nil {
		t.Fatalf("encode config: %v", err)
	}
	if err := os.WriteFile(filepath.Join(directory, "config.json"), append(contents, '\n'), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}
}

func (e *cliEnv) environ() []string {
	environment := append(os.Environ(),
		"XDG_CONFIG_HOME="+e.configHome,
		"HOME="+e.home,
		"TMPDIR="+e.temp,
	)
	return append(environment, e.extra...)
}

func (e *cliEnv) command(stdin io.Reader, args ...string) *exec.Cmd {
	command := exec.Command(cliBinary, args...)
	command.Env = e.environ()
	command.Stdin = stdin
	return command
}

type cliResult struct {
	stdout string
	stderr string
	exit   int
}

func (r cliResult) combined() string { return r.stdout + r.stderr }

func (e *cliEnv) run(t *testing.T, stdin []byte, args ...string) cliResult {
	t.Helper()
	var stdout, stderr bytes.Buffer
	command := e.command(bytes.NewReader(stdin), args...)
	command.Stdout = &stdout
	command.Stderr = &stderr
	err := command.Run()
	exit := 0
	if err != nil {
		var exitError *exec.ExitError
		if errors.As(err, &exitError) {
			exit = exitError.ExitCode()
		} else {
			t.Fatalf("running %v failed: %v", args, err)
		}
	}
	return cliResult{stdout: stdout.String(), stderr: stderr.String(), exit: exit}
}

// recordedRequest is one HTTP request the client made, captured at a
// transparent recording hop in front of the real server.
type recordedRequest struct {
	Method string
	Path   string
	Body   []byte
}

type recorder struct {
	mu      sync.Mutex
	entries []recordedRequest
}

func (r *recorder) record(method string, path string, body []byte) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.entries = append(r.entries, recordedRequest{Method: method, Path: path, Body: append([]byte(nil), body...)})
}

func (r *recorder) reset() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.entries = nil
}

func (r *recorder) snapshot() []recordedRequest {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]recordedRequest(nil), r.entries...)
}

// secretWrites are the runtime-secret and fetch-credential deliveries.
func (r *recorder) secretWrites() []recordedRequest {
	var writes []recordedRequest
	for _, entry := range r.snapshot() {
		if entry.Method == http.MethodPut &&
			(strings.Contains(entry.Path, "/secrets/") || strings.Contains(entry.Path, "/fetch-credentials")) {
			writes = append(writes, entry)
		}
	}
	return writes
}

func (r *recorder) raw() []byte {
	var all bytes.Buffer
	for _, entry := range r.snapshot() {
		all.WriteString(entry.Method)
		all.WriteString(" ")
		all.WriteString(entry.Path)
		all.WriteString("\n")
		all.Write(entry.Body)
		all.WriteString("\n")
	}
	return all.Bytes()
}

// startRecordingProxy runs a transparent reverse proxy to the real server. It
// records every request body verbatim and can delay the upstream response so a
// test can inspect the client while its request is in flight. It is not a
// substitute API: every request reaches the real Phoenix server and the real
// response is returned.
func startRecordingProxy(t *testing.T, target string, delay time.Duration) (string, *recorder) {
	t.Helper()
	return startRecordingProxyFor(t, target, func(string, string) time.Duration { return delay })
}

// startRecordingProxyFor is startRecordingProxy with a per-request delay, so a
// test can hold one request open without slowing every other call.
func startRecordingProxyFor(t *testing.T, target string, delayFor func(method string, path string) time.Duration) (string, *recorder) {
	t.Helper()
	parsed, err := url.Parse(target)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		t.Fatalf("BIOT_E2E_SERVER %q is not an absolute URL", target)
	}
	recorder := &recorder{}
	proxy := httputil.NewSingleHostReverseProxy(parsed)
	originalDirector := proxy.Director
	proxy.Director = func(request *http.Request) {
		originalDirector(request)
		// The real server dispatches on the control host, so the proxy must
		// present the upstream host rather than its own.
		request.Host = parsed.Host
	}
	handler := http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		body, err := io.ReadAll(request.Body)
		if err != nil {
			http.Error(response, err.Error(), http.StatusBadGateway)
			return
		}
		_ = request.Body.Close()
		recorder.record(request.Method, request.URL.Path, body)
		request.Body = io.NopCloser(bytes.NewReader(body))
		if delay := delayFor(request.Method, request.URL.Path); delay > 0 {
			time.Sleep(delay)
		}
		proxy.ServeHTTP(response, request)
	})
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	return server.URL, recorder
}

// processTree returns pid and every descendant of it.
func processTree(root int) []int {
	parents := map[int]int{}
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return nil
	}
	for _, entry := range entries {
		pid, err := strconv.Atoi(entry.Name())
		if err != nil {
			continue
		}
		status, err := os.ReadFile(filepath.Join("/proc", entry.Name(), "status"))
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(status), "\n") {
			if strings.HasPrefix(line, "PPid:") {
				parent, err := strconv.Atoi(strings.TrimSpace(strings.TrimPrefix(line, "PPid:")))
				if err == nil {
					parents[pid] = parent
				}
				break
			}
		}
	}
	result := []int{root}
	for candidate := range parents {
		for current, hops := candidate, 0; hops < 64; hops++ {
			parent, ok := parents[current]
			if !ok {
				break
			}
			if parent == root {
				result = append(result, candidate)
				break
			}
			current = parent
		}
	}
	return result
}

func procBytes(pid int, name string) []byte {
	contents, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), name))
	if err != nil {
		return nil
	}
	return contents
}

// processTableContains reports the pids whose command line or environment
// contains the needle.
func processTableContains(pids []int, needle []byte) []int {
	var found []int
	for _, pid := range pids {
		cmdline := bytes.ReplaceAll(procBytes(pid, "cmdline"), []byte{0}, []byte{' '})
		environ := bytes.ReplaceAll(procBytes(pid, "environ"), []byte{0}, []byte{'\n'})
		if bytes.Contains(cmdline, needle) || bytes.Contains(environ, needle) {
			found = append(found, pid)
		}
	}
	return found
}

// openPTY returns a master and slave pair. The caller closes both.
func openPTY(t *testing.T) (*os.File, *os.File) {
	t.Helper()
	master, err := os.OpenFile("/dev/ptmx", os.O_RDWR, 0)
	if err != nil {
		t.Fatalf("open /dev/ptmx: %v", err)
	}
	if err := unix.IoctlSetPointerInt(int(master.Fd()), unix.TIOCSPTLCK, 0); err != nil {
		master.Close()
		t.Fatalf("unlock pty: %v", err)
	}
	number, err := unix.IoctlGetInt(int(master.Fd()), unix.TIOCGPTN)
	if err != nil {
		master.Close()
		t.Fatalf("read pty number: %v", err)
	}
	slave, err := os.OpenFile(fmt.Sprintf("/dev/pts/%d", number), os.O_RDWR|unix.O_NOCTTY, 0)
	if err != nil {
		master.Close()
		t.Fatalf("open pty slave: %v", err)
	}
	return master, slave
}

// ptyProcess is a command attached to a controlling terminal.
type ptyProcess struct {
	command  *exec.Cmd
	master   *os.File
	output   *safeBuffer
	readDone chan struct{}
	waitDone chan struct{}
	waitErr  error
}

type safeBuffer struct {
	mu      sync.Mutex
	content bytes.Buffer
}

func (b *safeBuffer) Write(value []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.content.Write(value)
}

func (b *safeBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.content.String()
}

func startPTYCommand(t *testing.T, env *cliEnv, args ...string) *ptyProcess {
	t.Helper()
	return startPTYExec(t, env, cliBinary, args...)
}

func startPTYExec(t *testing.T, env *cliEnv, program string, args ...string) *ptyProcess {
	t.Helper()
	master, slave := openPTY(t)
	command := exec.Command(program, args...)
	command.Env = env.environ()
	command.Stdin = slave
	command.Stdout = slave
	command.Stderr = slave
	command.SysProcAttr = &unix.SysProcAttr{Setsid: true, Setctty: true, Ctty: 0}
	output := &safeBuffer{}
	process := &ptyProcess{command: command, master: master, output: output, readDone: make(chan struct{}), waitDone: make(chan struct{})}
	if err := command.Start(); err != nil {
		master.Close()
		slave.Close()
		t.Fatalf("start %v on a pty: %v", args, err)
	}
	slave.Close()
	go func() {
		_, _ = io.Copy(output, master)
		close(process.readDone)
	}()
	go func() {
		process.waitErr = command.Wait()
		close(process.waitDone)
	}()
	return process
}

func (p *ptyProcess) write(t *testing.T, value string) {
	t.Helper()
	if _, err := p.master.WriteString(value); err != nil {
		t.Fatalf("write to pty: %v", err)
	}
}

// waitForOutput waits until the process output contains marker.
func (p *ptyProcess) waitForOutput(t *testing.T, marker string, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if strings.Contains(p.output.String(), marker) {
			return
		}
		select {
		case <-p.waitDone:
			t.Fatalf("process exited before printing %q; output:\n%s", marker, p.output.String())
		default:
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %q; output:\n%s", marker, p.output.String())
}

func (p *ptyProcess) waitForExit(t *testing.T, timeout time.Duration) int {
	t.Helper()
	select {
	case <-p.waitDone:
	case <-time.After(timeout):
		t.Fatalf("process did not exit; output:\n%s", p.output.String())
	}
	if p.waitErr != nil {
		var exitError *exec.ExitError
		if errors.As(p.waitErr, &exitError) {
			return exitError.ExitCode()
		}
		t.Fatalf("process failed: %v", p.waitErr)
	}
	return 0
}

func randomToken(t *testing.T, prefix string) string {
	t.Helper()
	value := make([]byte, 12)
	if _, err := rand.Read(value); err != nil {
		t.Fatalf("random: %v", err)
	}
	return prefix + fmt.Sprintf("%x", value)
}

// randomName returns a lowercase Biot name with a random suffix, so a test run
// never collides with an earlier one.
func randomName(t *testing.T, prefix string) string {
	t.Helper()
	value := make([]byte, 6)
	if _, err := rand.Read(value); err != nil {
		t.Fatalf("random: %v", err)
	}
	return prefix + fmt.Sprintf("%x", value)
}

// runningCLI is a pipe-backed command that can be inspected while it runs.
type runningCLI struct {
	command  *exec.Cmd
	stdout   *safeBuffer
	stderr   *safeBuffer
	waitDone chan struct{}
	waitErr  error
}

func (e *cliEnv) start(t *testing.T, stdin io.Reader, args ...string) *runningCLI {
	t.Helper()
	command := e.command(stdin, args...)
	stdout := &safeBuffer{}
	stderr := &safeBuffer{}
	command.Stdout = stdout
	command.Stderr = stderr
	process := &runningCLI{command: command, stdout: stdout, stderr: stderr, waitDone: make(chan struct{})}
	if err := command.Start(); err != nil {
		t.Fatalf("start %v: %v", args, err)
	}
	go func() {
		process.waitErr = command.Wait()
		close(process.waitDone)
	}()
	return process
}

func (r *runningCLI) wait(t *testing.T, timeout time.Duration) cliResult {
	t.Helper()
	select {
	case <-r.waitDone:
	case <-time.After(timeout):
		t.Fatalf("command did not exit; stdout:\n%s\nstderr:\n%s", r.stdout.String(), r.stderr.String())
	}
	exit := 0
	if r.waitErr != nil {
		var exitError *exec.ExitError
		if errors.As(r.waitErr, &exitError) {
			exit = exitError.ExitCode()
		} else {
			t.Fatalf("command failed: %v", r.waitErr)
		}
	}
	return cliResult{stdout: r.stdout.String(), stderr: r.stderr.String(), exit: exit}
}
