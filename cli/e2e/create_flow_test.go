//go:build e2e

package e2e

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

// TestCreateWithoutCredentialsReachesReady drives the plain create path
// against a real node: the CLI creates a running Biot, waits for the lifecycle
// operation, and prints the ready line.
func TestCreateWithoutCredentialsReachesReady(t *testing.T) {
	token := requireEnv(t, "BIOT_E2E_TOKEN")
	node := requireNode(t)
	env := newCLIEnv(t)
	env.writeConfig(t, serverURL(t), token)

	name := randomName(t, "plain-")
	result := env.run(t, nil, "create",
		"--repo", "https://github.com/example/plain.git",
		"--name", name,
		"--node", node)
	if result.exit != 0 {
		t.Fatalf("create exited %d:\n%s", result.exit, result.combined())
	}
	for _, phase := range []string{"biot creating", "biot preparing", "biot starting", "biot ready"} {
		if !strings.Contains(result.stdout, phase) {
			t.Fatalf("create did not print %q:\n%s", phase, result.stdout)
		}
	}
	assertRunning(t, env, name)
}

// TestCreateWithCredentialsReachesReady is the flow a person with a private
// repository and runtime secrets actually runs. It supplies a fetch credential
// and two runtime secrets at the hidden prompts, in order, and checks both what
// the CLI printed and what the server stored.
func TestCreateWithCredentialsReachesReady(t *testing.T) {
	token := requireEnv(t, "BIOT_E2E_TOKEN")
	node := requireNode(t)
	proxyURL, recorder := startRecordingProxy(t, serverURL(t), 0)
	env := newCLIEnv(t)
	env.writeConfig(t, proxyURL, token)

	name := randomName(t, "credentialed-")
	source := "https://github.com/example/credentialed.git"
	fetchValue := randomToken(t, "S3CR3T-FETCH-")
	tokenValue := randomToken(t, "S3CR3T-TOKEN-")
	keyValue := randomToken(t, "S3CR3T-KEY-")

	process := startPTYCommand(t, env, "create",
		"--repo", source,
		"--name", name,
		"--node", node,
		"--fetch-credential", source,
		"--secret", "TOKEN",
		"--secret", "API_KEY")

	process.waitForOutput(t, "biot creating", 90*time.Second)
	process.waitForOutput(t, "Source-fetch credential for "+source+": ", 90*time.Second)
	if strings.Contains(process.output.String(), "Runtime secret TOKEN: ") {
		t.Fatalf("the runtime secret was prompted before the fetch credential:\n%s", process.output.String())
	}
	time.Sleep(150 * time.Millisecond)
	process.write(t, fetchValue+"\n")

	process.waitForOutput(t, "Runtime secret TOKEN: ", 90*time.Second)
	time.Sleep(150 * time.Millisecond)
	process.write(t, tokenValue+"\n")

	process.waitForOutput(t, "Runtime secret API_KEY: ", 90*time.Second)
	time.Sleep(150 * time.Millisecond)
	process.write(t, keyValue+"\n")

	process.waitForOutput(t, "biot ready", 120*time.Second)
	if exit := process.waitForExit(t, 30*time.Second); exit != 0 {
		t.Fatalf("create exited %d:\n%s", exit, process.output.String())
	}
	output := process.output.String()
	fetchPrompt := strings.Index(output, "Source-fetch credential for "+source+": ")
	tokenPrompt := strings.Index(output, "Runtime secret TOKEN: ")
	keyPrompt := strings.Index(output, "Runtime secret API_KEY: ")
	if !(fetchPrompt < tokenPrompt && tokenPrompt < keyPrompt) {
		t.Fatalf("prompts appeared out of order (fetch %d, token %d, key %d):\n%s", fetchPrompt, tokenPrompt, keyPrompt, output)
	}

	assertRunning(t, env, name)

	writes := recorder.secretWrites()
	if len(writes) != 3 {
		t.Fatalf("expected one fetch credential and two secrets, got %d writes", len(writes))
	}
	assertDelivery(t, writes[0], "/fetch-credentials", map[string]string{"source": source, "value": fetchValue})
	assertDelivery(t, writes[1], "/secrets/TOKEN", map[string]string{"value": tokenValue})
	assertDelivery(t, writes[2], "/secrets/API_KEY", map[string]string{"value": keyValue})

	if strings.Contains(output, fetchValue) || strings.Contains(output, tokenValue) || strings.Contains(output, keyValue) {
		t.Fatalf("a hidden prompt echoed a value:\n%s", output)
	}
}

// TestCreateWithStdinCredentialReachesReady covers the non-interactive form of
// the same flow: one credential from standard input, delivered, then ready.
func TestCreateWithStdinCredentialReachesReady(t *testing.T) {
	token := requireEnv(t, "BIOT_E2E_TOKEN")
	node := requireNode(t)
	proxyURL, recorder := startRecordingProxy(t, serverURL(t), 0)
	env := newCLIEnv(t)
	env.writeConfig(t, proxyURL, token)

	name := randomName(t, "stdin-")
	value := randomToken(t, "S3CR3T-STDIN-CREATE-")
	result := env.run(t, []byte(value), "create",
		"--repo", "https://github.com/example/stdin.git",
		"--name", name,
		"--node", node,
		"--secret", "TOKEN",
		"--stdin")
	if result.exit != 0 {
		t.Fatalf("create exited %d:\n%s", result.exit, result.combined())
	}
	if !strings.Contains(result.stdout, "biot ready") {
		t.Fatalf("create did not reach ready:\n%s", result.stdout)
	}
	if strings.Contains(result.combined(), value) {
		t.Fatalf("the client printed the value:\n%s", result.combined())
	}
	assertRunning(t, env, name)

	writes := recorder.secretWrites()
	if len(writes) != 1 {
		t.Fatalf("expected one secret delivery, got %d", len(writes))
	}
	assertDelivery(t, writes[0], "/secrets/TOKEN", map[string]string{"value": value})
}

// assertRunning asks the server for the Biot's state rather than trusting the
// CLI's own ready line. The desired state is the server's own record, so a wrong
// one fails at once; the container is the node's report, so it is waited for.
func assertRunning(t *testing.T, env *cliEnv, name string) {
	t.Helper()
	show := env.run(t, nil, "show", name)
	if show.exit != 0 {
		t.Fatalf("show %s exited %d:\n%s", name, show.exit, show.combined())
	}
	if !strings.Contains(show.stdout, "desired: running") {
		t.Fatalf("the server does not report %s as desired running:\n%s", name, show.stdout)
	}
	waitForShow(t, env, name, "container: running")
}

func assertDelivery(t *testing.T, entry recordedRequest, path string, fields map[string]string) {
	t.Helper()
	if !strings.Contains(entry.Path, path) {
		t.Fatalf("delivery went to %q, want %q", entry.Path, path)
	}
	var payload map[string]any
	if err := json.Unmarshal(entry.Body, &payload); err != nil {
		t.Fatalf("delivery body is not JSON: %v\n%s", err, entry.Body)
	}
	for key, want := range fields {
		got, ok := payload[key]
		if !ok {
			t.Fatalf("delivery to %s is missing %q: %s", path, key, entry.Body)
		}
		if got != want {
			t.Fatalf("delivery to %s carried %s=%q, want %q", path, key, got, want)
		}
	}
}
