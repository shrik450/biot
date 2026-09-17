//go:build e2e

package e2e

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestSecretBytesReachTheServerUnchanged is the heart of the secret contract:
// the bytes the person supplies are the bytes the server receives. A value is
// bytes, not text, so a trailing newline, an embedded newline, a NUL, and an
// empty value must all survive JSON transport exactly. The recorder captures
// the raw request body at a transparent hop in front of the real server.
func TestSecretBytesReachTheServerUnchanged(t *testing.T) {
	token := requireEnv(t, "BIOT_E2E_TOKEN")
	biot := requireEnv(t, "BIOT_E2E_BIOT")
	proxyURL, recorder := startRecordingProxy(t, serverURL(t), 0)
	env := newCLIEnv(t)
	env.writeConfig(t, proxyURL, token)

	cases := []struct {
		name  string
		value []byte
	}{
		{"trailing newline", []byte("alpha\n")},
		{"embedded newline", []byte("alpha\nbeta")},
		{"nul byte", []byte("alpha\x00beta")},
		{"empty value", []byte{}},
		{"exactly at the size bound", bytes.Repeat([]byte("x"), 64*1024)},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			recorder.reset()
			result := env.run(t, test.value, "secret", "set", biot, "E2E_BYTES", "--stdin")
			if result.exit == 0 {
				t.Fatalf("delivery to a node-less Biot should fail, got success:\n%s", result.combined())
			}
			writes := recorder.secretWrites()
			if len(writes) != 1 {
				t.Fatalf("expected exactly one secret write, got %d", len(writes))
			}
			var payload struct {
				Value string `json:"value"`
			}
			if err := json.Unmarshal(writes[0].Body, &payload); err != nil {
				t.Fatalf("secret body is not JSON: %v\n%s", err, writes[0].Body)
			}
			if !bytes.Equal([]byte(payload.Value), test.value) {
				t.Fatalf("the server received %d bytes %q, want %d bytes %q", len(payload.Value), payload.Value, len(test.value), test.value)
			}
		})
	}
}

// TestNulByteReachesTheRealParser pins the byte-identity result to the real
// server's own distinction: a NUL is refused with nul_byte, while a rewritten
// value (for example U+FFFD) would pass parsing and fail later on the missing
// node instead.
func TestNulByteReachesTheRealParser(t *testing.T) {
	token := requireEnv(t, "BIOT_E2E_TOKEN")
	biot := requireEnv(t, "BIOT_E2E_BIOT")
	env := newCLIEnv(t)
	env.writeConfig(t, serverURL(t), token)

	result := env.run(t, []byte("alpha\x00beta"), "secret", "set", biot, "E2E_NUL", "--stdin")
	if result.exit == 0 {
		t.Fatalf("a NUL value should be refused, got success:\n%s", result.combined())
	}
	if !strings.Contains(result.combined(), "must not contain a NUL byte") {
		t.Fatalf("the real server's nul_byte reason did not reach the person:\n%s", result.combined())
	}
}

// TestInvalidUTF8IsRefusedNotRewritten covers the other half of the byte
// contract: this HTTP API carries values as JSON strings, so invalid UTF-8
// cannot travel faithfully. The client must refuse before sending rather than
// let encoding/json replace the bytes with U+FFFD.
func TestInvalidUTF8IsRefusedNotRewritten(t *testing.T) {
	token := requireEnv(t, "BIOT_E2E_TOKEN")
	biot := requireEnv(t, "BIOT_E2E_BIOT")
	proxyURL, recorder := startRecordingProxy(t, serverURL(t), 0)
	env := newCLIEnv(t)
	env.writeConfig(t, proxyURL, token)

	result := env.run(t, []byte{0x61, 0xff, 0xfe, 0x62}, "secret", "set", biot, "E2E_INVALID", "--stdin")
	if result.exit == 0 {
		t.Fatalf("an invalid UTF-8 value should be refused, got success:\n%s", result.combined())
	}
	if !strings.Contains(result.combined(), "valid UTF-8") {
		t.Fatalf("the refusal should name the UTF-8 constraint:\n%s", result.combined())
	}
	if writes := recorder.secretWrites(); len(writes) != 0 {
		t.Fatalf("the client sent %d secret write(s) for an invalid value", len(writes))
	}
	if bytes.Contains(recorder.raw(), []byte{0xef, 0xbf, 0xbd}) {
		t.Fatal("the client sent U+FFFD where invalid bytes used to be")
	}
}

// TestHiddenPromptDoesNotLeakToProcessTable types a value at the hidden prompt
// and samples /proc for the client and every child while the delivery is in
// flight. The value must never appear in an argv or an environment.
func TestHiddenPromptDoesNotLeakToProcessTable(t *testing.T) {
	token := requireEnv(t, "BIOT_E2E_TOKEN")
	biot := requireEnv(t, "BIOT_E2E_BIOT")
	proxyURL, recorder := startRecordingProxy(t, serverURL(t), 3*time.Second)
	env := newCLIEnv(t)
	env.writeConfig(t, proxyURL, token)

	secret := randomToken(t, "S3CR3T-HIDDEN-")
	process := startPTYCommand(t, env, "secret", "set", biot, "E2E_HIDDEN")
	process.waitForOutput(t, "Runtime secret value: ", 15*time.Second)
	// Give the client time to disable terminal echo before typing.
	time.Sleep(150 * time.Millisecond)
	process.write(t, secret+"\n")

	var leaked []int
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		pids := processTree(process.command.Process.Pid)
		leaked = append(leaked, processTableContains(pids, []byte(secret))...)
		time.Sleep(10 * time.Millisecond)
	}
	if len(leaked) > 0 {
		t.Fatalf("the secret appeared in the process table of pid(s) %v", leaked)
	}
	process.waitForExit(t, 15*time.Second)
	if strings.Contains(process.output.String(), secret) {
		t.Fatalf("the hidden prompt echoed the value:\n%s", process.output.String())
	}
	if writes := recorder.secretWrites(); len(writes) != 1 {
		t.Fatalf("the hidden prompt delivered %d values, want 1; the leak check did not exercise a delivery", len(writes))
	}
}

// TestStdinSecretDoesNotLeakToProcessTable does the same for the explicit
// --stdin path.
func TestStdinSecretDoesNotLeakToProcessTable(t *testing.T) {
	token := requireEnv(t, "BIOT_E2E_TOKEN")
	biot := requireEnv(t, "BIOT_E2E_BIOT")
	proxyURL, recorder := startRecordingProxy(t, serverURL(t), 3*time.Second)
	env := newCLIEnv(t)
	env.writeConfig(t, proxyURL, token)

	secret := randomToken(t, "S3CR3T-STDIN-")
	process := env.start(t, strings.NewReader(secret), "secret", "set", biot, "E2E_STDIN", "--stdin")

	var leaked []int
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		pids := processTree(process.command.Process.Pid)
		leaked = append(leaked, processTableContains(pids, []byte(secret))...)
		time.Sleep(10 * time.Millisecond)
	}
	if len(leaked) > 0 {
		t.Fatalf("the secret appeared in the process table of pid(s) %v", leaked)
	}
	result := process.wait(t, 15*time.Second)
	if strings.Contains(result.combined(), secret) {
		t.Fatalf("the client printed the value:\n%s", result.combined())
	}
	if writes := recorder.secretWrites(); len(writes) != 1 {
		t.Fatalf("--stdin delivered %d values, want 1; the leak check did not exercise a delivery", len(writes))
	}
}

// TestStdinReadsExactlyOneValue proves --stdin treats the whole stream as one
// value rather than one value per line, and that it never echoes it.
func TestStdinReadsExactlyOneValue(t *testing.T) {
	token := requireEnv(t, "BIOT_E2E_TOKEN")
	biot := requireEnv(t, "BIOT_E2E_BIOT")
	proxyURL, recorder := startRecordingProxy(t, serverURL(t), 0)
	env := newCLIEnv(t)
	env.writeConfig(t, proxyURL, token)

	value := []byte("first\nsecond\nthird\n")
	recorder.reset()
	result := env.run(t, value, "secret", "set", biot, "E2E_ONE_VALUE", "--stdin")
	writes := recorder.secretWrites()
	if len(writes) != 1 {
		t.Fatalf("expected one delivery, got %d", len(writes))
	}
	var payload struct {
		Value string `json:"value"`
	}
	if err := json.Unmarshal(writes[0].Body, &payload); err != nil {
		t.Fatalf("secret body is not JSON: %v", err)
	}
	if payload.Value != string(value) {
		t.Fatalf("--stdin delivered %q, want the whole stream %q", payload.Value, value)
	}
	if strings.Contains(result.combined(), "first") {
		t.Fatalf("the client echoed the value:\n%s", result.combined())
	}
}

// TestFailedDeliveryWritesTheValueNowhere checks every file the client can
// write, its output, and the request count on a failed delivery. The failure
// path is where a secret would hide.
func TestFailedDeliveryWritesTheValueNowhere(t *testing.T) {
	token := requireEnv(t, "BIOT_E2E_TOKEN")
	biot := requireEnv(t, "BIOT_E2E_BIOT")
	proxyURL, recorder := startRecordingProxy(t, serverURL(t), 0)
	env := newCLIEnv(t)
	env.writeConfig(t, proxyURL, token)

	secret := randomToken(t, "S3CR3T-FILE-")
	before := snapshotTree(t, env.configHome, env.home, env.temp)
	recorder.reset()
	result := env.run(t, []byte(secret), "secret", "set", biot, "E2E_FILE", "--stdin")
	if result.exit == 0 {
		t.Fatalf("delivery should have failed:\n%s", result.combined())
	}
	if strings.Contains(result.combined(), secret) {
		t.Fatalf("the failure output contained the value:\n%s", result.combined())
	}
	if writes := recorder.secretWrites(); len(writes) != 1 {
		t.Fatalf("a failed delivery made %d attempts; it must not retry", len(writes))
	}
	after := snapshotTree(t, env.configHome, env.home, env.temp)
	for path, contents := range after {
		if bytes.Contains(contents, []byte(secret)) {
			t.Fatalf("the value was written to %s", path)
		}
	}
	for path := range before {
		if _, still := after[path]; !still {
			t.Logf("file removed during the run: %s", path)
		}
	}
	if found := treeContains(t, secret, env.configHome, env.home, env.temp); found != "" {
		t.Fatalf("the value was written to %s", found)
	}
}

// TestHiddenPromptDoesNotEnterShellHistory runs an interactive shell with a
// real history file, types the command and then the value at the hidden
// prompt, and proves the shell recorded the command but never the value.
func TestHiddenPromptDoesNotEnterShellHistory(t *testing.T) {
	token := requireEnv(t, "BIOT_E2E_TOKEN")
	biot := requireEnv(t, "BIOT_E2E_BIOT")
	proxyURL, recorder := startRecordingProxy(t, serverURL(t), 500*time.Millisecond)
	env := newCLIEnv(t)
	env.writeConfig(t, proxyURL, token)

	historyFile := filepath.Join(env.home, ".bash_history")
	env.extra = append(env.extra, "HISTFILE="+historyFile, "PS1=PROMPT> ", "PROMPT_COMMAND=")
	secret := randomToken(t, "S3CR3T-HIST-")
	process := startPTYExec(t, env, "bash", "--norc", "-i")
	process.waitForOutput(t, "PROMPT>", 15*time.Second)
	process.write(t, cliBinary+" secret set "+biot+" E2E_HISTORY; echo E2E_COMMAND_DONE\n")
	process.waitForOutput(t, "Runtime secret value: ", 15*time.Second)
	time.Sleep(150 * time.Millisecond)
	process.write(t, secret+"\n")
	process.waitForOutput(t, "E2E_COMMAND_DONE", 15*time.Second)
	process.write(t, "exit\n")
	process.waitForExit(t, 15*time.Second)

	if writes := recorder.secretWrites(); len(writes) != 1 {
		t.Fatalf("the shell-typed hidden prompt delivered %d values, want 1; history was not exercised", len(writes))
	}
	history, err := os.ReadFile(historyFile)
	if err != nil {
		t.Fatalf("read shell history: %v", err)
	}
	if !strings.Contains(string(history), "secret set") {
		t.Fatalf("the shell did not record the command; the test is not exercising history:\n%s", history)
	}
	if strings.Contains(string(history), secret) {
		t.Fatalf("the value reached the shell history:\n%s", history)
	}
	if strings.Contains(process.output.String(), secret) {
		t.Fatalf("the hidden prompt echoed the value:\n%s", process.output.String())
	}
}

// TestProcessTableDetectorFindsAPlantedValue proves the leak detector is not
// silently empty: a value planted in a child's argv and a value planted in a
// child's environment are both found.
func TestProcessTableDetectorFindsAPlantedValue(t *testing.T) {
	argvSecret := randomToken(t, "S3CR3T-ARGV-")
	argvCommand := exec.Command("sh", "-c", "sleep 5", argvSecret)
	if err := argvCommand.Start(); err != nil {
		t.Fatalf("start argv probe: %v", err)
	}
	defer argvCommand.Process.Kill()

	envSecret := randomToken(t, "S3CR3T-ENV-")
	envCommand := exec.Command("sleep", "5")
	envCommand.Env = append(os.Environ(), "PLANTED="+envSecret)
	if err := envCommand.Start(); err != nil {
		t.Fatalf("start env probe: %v", err)
	}
	defer envCommand.Process.Kill()

	argvDeadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(argvDeadline) && len(processTableContains([]int{argvCommand.Process.Pid}, []byte(argvSecret))) == 0 {
		time.Sleep(5 * time.Millisecond)
	}
	if found := processTableContains([]int{argvCommand.Process.Pid}, []byte(argvSecret)); len(found) == 0 {
		t.Fatal("the detector did not find a value planted in argv")
	}

	envDeadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(envDeadline) && len(processTableContains([]int{envCommand.Process.Pid}, []byte(envSecret))) == 0 {
		time.Sleep(5 * time.Millisecond)
	}
	if found := processTableContains([]int{envCommand.Process.Pid}, []byte(envSecret)); len(found) == 0 {
		t.Fatal("the detector did not find a value planted in the environment")
	}
}

// TestSeveralSecretNamesPromptInOrder proves the hidden prompts are separate
// and serialized: the second prompt appears only after the first delivery has
// been answered by the server. The proxy holds the first delivery open, so the
// window where the request is in flight is observable.
func TestSeveralSecretNamesPromptInOrder(t *testing.T) {
	token := requireEnv(t, "BIOT_E2E_TOKEN")
	node := requireNode(t)
	proxyURL, recorder := startRecordingProxyFor(t, serverURL(t), func(method string, path string) time.Duration {
		if method == "PUT" && strings.Contains(path, "/secrets/") {
			return 3 * time.Second
		}
		return 0
	})
	env := newCLIEnv(t)
	env.writeConfig(t, proxyURL, token)

	name := randomName(t, "prompts-")
	first := randomToken(t, "S3CR3T-FIRST-")
	second := randomToken(t, "S3CR3T-SECOND-")

	process := startPTYCommand(t, env, "create",
		"--repo", "https://github.com/example/prompts.git",
		"--name", name,
		"--node", node,
		"--secret", "ALPHA",
		"--secret", "BETA")

	process.waitForOutput(t, "Runtime secret ALPHA: ", 90*time.Second)
	if strings.Contains(process.output.String(), "Runtime secret BETA: ") {
		t.Fatalf("the second prompt appeared before the first value was typed:\n%s", process.output.String())
	}

	time.Sleep(150 * time.Millisecond)
	process.write(t, first+"\n")

	// Wait until the first delivery has reached the server, then prove the
	// second prompt is still absent while the answer is held open.
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) && len(recorder.secretWrites()) == 0 {
		time.Sleep(10 * time.Millisecond)
	}
	if writes := recorder.secretWrites(); len(writes) != 1 {
		t.Fatalf("expected the first delivery to be in flight, saw %d writes:\n%s", len(writes), process.output.String())
	}
	if strings.Contains(process.output.String(), "Runtime secret BETA: ") {
		t.Fatalf("the second prompt appeared while the first delivery was unanswered:\n%s", process.output.String())
	}
	time.Sleep(time.Second)
	if strings.Contains(process.output.String(), "Runtime secret BETA: ") {
		t.Fatalf("the second prompt appeared while the first delivery was unanswered:\n%s", process.output.String())
	}

	process.waitForOutput(t, "Runtime secret BETA: ", 30*time.Second)
	time.Sleep(150 * time.Millisecond)
	process.write(t, second+"\n")
	process.waitForOutput(t, "biot ready", 90*time.Second)
	if exit := process.waitForExit(t, 30*time.Second); exit != 0 {
		t.Fatalf("create exited %d:\n%s", exit, process.output.String())
	}

	writes := recorder.secretWrites()
	if len(writes) != 2 {
		t.Fatalf("expected two deliveries, got %d", len(writes))
	}
	for index, want := range []struct {
		path  string
		value string
	}{{"/secrets/ALPHA", first}, {"/secrets/BETA", second}} {
		if !strings.Contains(writes[index].Path, want.path) {
			t.Fatalf("delivery %d went to %q, want %q", index, writes[index].Path, want.path)
		}
		var payload struct {
			Value string `json:"value"`
		}
		if err := json.Unmarshal(writes[index].Body, &payload); err != nil {
			t.Fatalf("delivery %d body is not JSON: %v", index, err)
		}
		if payload.Value != want.value {
			t.Fatalf("delivery %d carried %q, want %q", index, payload.Value, want.value)
		}
	}
	if strings.Contains(process.output.String(), first) || strings.Contains(process.output.String(), second) {
		t.Fatalf("the hidden prompts echoed a value:\n%s", process.output.String())
	}
}

func snapshotTree(t *testing.T, roots ...string) map[string][]byte {
	t.Helper()
	files := map[string][]byte{}
	for _, root := range roots {
		_ = filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
			if err != nil || entry.IsDir() {
				return nil
			}
			contents, err := os.ReadFile(path)
			if err != nil {
				return nil
			}
			files[path] = contents
			return nil
		})
	}
	return files
}

func treeContains(t *testing.T, needle string, roots ...string) string {
	t.Helper()
	for path, contents := range snapshotTree(t, roots...) {
		if bytes.Contains(contents, []byte(needle)) {
			return path
		}
	}
	return ""
}
