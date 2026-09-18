//go:build e2e

package e2e

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// TestLifecycleCommands drives stop, wait, start, restart, rebuild, and
// destroy against a real node, and checks the end state the server reports
// rather than only the transient messages.
func TestLifecycleCommands(t *testing.T) {
	token := requireEnv(t, "BIOT_E2E_TOKEN")
	node := requireNode(t)
	env := newCLIEnv(t)
	env.writeConfig(t, serverURL(t), token)

	name := randomName(t, "lifecycle-")
	if result := env.run(t, nil, "create", "--repo", "https://github.com/example/lifecycle.git", "--name", name, "--node", node); result.exit != 0 {
		t.Fatalf("create exited %d:\n%s", result.exit, result.combined())
	}
	assertRunning(t, env, name)

	// stop -> wait -> absent
	if result := env.run(t, nil, "stop", name); result.exit != 0 {
		t.Fatalf("stop exited %d:\n%s", result.exit, result.combined())
	}
	if result := env.run(t, nil, "wait", name); result.exit != 0 {
		t.Fatalf("wait after stop exited %d:\n%s", result.exit, result.combined())
	}
	assertContainer(t, env, name, "absent")

	// stop again is a no-op the CLI names
	if result := env.run(t, nil, "stop", name); result.exit != 0 {
		t.Fatalf("second stop exited %d:\n%s", result.exit, result.combined())
	} else if !strings.Contains(result.stdout, "already stopped") {
		t.Fatalf("second stop did not say the Biot is already stopped:\n%s", result.stdout)
	}

	// start -> wait -> running
	if result := env.run(t, nil, "start", name); result.exit != 0 {
		t.Fatalf("start exited %d:\n%s", result.exit, result.combined())
	}
	if result := env.run(t, nil, "wait", name); result.exit != 0 {
		t.Fatalf("wait after start exited %d:\n%s", result.exit, result.combined())
	}
	assertRunning(t, env, name)

	// restart composes stop, wait, start
	if result := env.run(t, nil, "restart", name); result.exit != 0 {
		t.Fatalf("restart exited %d:\n%s", result.exit, result.combined())
	} else if !strings.Contains(result.stdout, "biot ready") {
		t.Fatalf("restart did not reach ready:\n%s", result.stdout)
	}
	assertRunning(t, env, name)

	// rebuild accepts a new operation for the same environment
	rebuild := env.run(t, nil, "rebuild", name)
	if rebuild.exit != 0 {
		t.Fatalf("rebuild exited %d:\n%s", rebuild.exit, rebuild.combined())
	}
	if !strings.Contains(rebuild.stdout, "accepted") && !strings.Contains(rebuild.stdout, "already current") {
		t.Fatalf("rebuild printed neither an accepted operation nor an unchanged message:\n%s", rebuild.stdout)
	}
	assertRunning(t, env, name)

	// destroy -> desired destroyed, no allocation
	destroy := env.run(t, nil, "destroy", name)
	if destroy.exit != 0 {
		t.Fatalf("destroy exited %d:\n%s", destroy.exit, destroy.combined())
	}
	show := env.run(t, nil, "show", name)
	if show.exit != 0 {
		t.Fatalf("show after destroy exited %d:\n%s", show.exit, show.combined())
	}
	if !strings.Contains(show.stdout, "desired: destroyed") {
		t.Fatalf("the server does not report the Biot destroyed:\n%s", show.stdout)
	}
	// The absent container is the node's report, which the destroy command does not wait for.
	assertContainer(t, env, name, "absent")
}

// TestRunningBiotCommands walks the commands a running Biot answers: runtime
// secrets, fetch credentials, publications, diagnostics, and logs.
func TestRunningBiotCommands(t *testing.T) {
	token := requireEnv(t, "BIOT_E2E_TOKEN")
	node := requireNode(t)
	env := newCLIEnv(t)
	env.writeConfig(t, serverURL(t), token)

	name := randomName(t, "commands-")
	if result := env.run(t, nil, "create", "--repo", "https://github.com/example/commands.git", "--name", name, "--node", node); result.exit != 0 {
		t.Fatalf("create exited %d:\n%s", result.exit, result.combined())
	}
	source := "https://github.com/example/commands.git"

	if result := env.run(t, []byte("runtime-value"), "secret", "set", name, "MY_SECRET", "--stdin"); result.exit != 0 {
		t.Fatalf("secret set exited %d:\n%s", result.exit, result.combined())
	} else if !strings.Contains(result.stdout, "Runtime secret MY_SECRET delivered.") {
		t.Fatalf("secret set did not report delivery:\n%s", result.stdout)
	}
	if result := env.run(t, nil, "secret", "list", name); result.exit != 0 {
		t.Fatalf("secret list exited %d:\n%s", result.exit, result.combined())
	} else if !strings.Contains(result.stdout, "No runtime secrets.") {
		t.Fatalf("the node reports no secrets, so list should say so:\n%s", result.stdout)
	}
	if result := env.run(t, nil, "secret", "rm", name, "MY_SECRET"); result.exit != 0 {
		t.Fatalf("secret rm exited %d:\n%s", result.exit, result.combined())
	}

	if result := env.run(t, []byte("fetch-value"), "fetch-credential", "set", name, source, "--stdin"); result.exit != 0 {
		t.Fatalf("fetch-credential set exited %d:\n%s", result.exit, result.combined())
	}
	if result := env.run(t, nil, "fetch-credential", "rm", name, source); result.exit != 0 {
		t.Fatalf("fetch-credential rm exited %d:\n%s", result.exit, result.combined())
	}

	if result := env.run(t, nil, "publish", name, "8080"); result.exit != 0 {
		t.Fatalf("publish exited %d:\n%s", result.exit, result.combined())
	} else if !strings.Contains(result.stdout, "Port 8080 published.") {
		t.Fatalf("publish did not report the port:\n%s", result.stdout)
	}
	if result := env.run(t, nil, "urls", name); result.exit != 0 {
		t.Fatalf("urls exited %d:\n%s", result.exit, result.combined())
	} else if !strings.Contains(result.stdout, ".env.test") {
		t.Fatalf("urls did not print a publication URL:\n%s", result.stdout)
	}
	if result := env.run(t, nil, "unpublish", name, "8080"); result.exit != 0 {
		t.Fatalf("unpublish exited %d:\n%s", result.exit, result.combined())
	}
	if result := env.run(t, nil, "urls", name); result.exit != 0 {
		t.Fatalf("urls after unpublish exited %d:\n%s", result.exit, result.combined())
	} else if !strings.Contains(result.stdout, "No published URLs.") {
		t.Fatalf("urls after unpublish should be empty:\n%s", result.stdout)
	}

	if result := env.run(t, nil, "diagnose", name); result.exit == 0 {
		t.Fatalf("diagnose on a healthy Biot should fail:\n%s", result.combined())
	} else if !strings.Contains(result.combined(), "no current failure diagnostic") {
		t.Fatalf("diagnose did not explain the missing failure:\n%s", result.combined())
	}
	if result := env.run(t, nil, "logs", name); result.exit == 0 {
		t.Fatalf("logs against a node that reports not_found should fail:\n%s", result.combined())
	} else if !strings.Contains(result.combined(), "not found") {
		t.Fatalf("logs did not report the missing resource:\n%s", result.combined())
	}
}

// TestNameResolutionByNameAndID resolves the same Biot both ways and checks the
// not-found sentence.
func TestNameResolutionByNameAndID(t *testing.T) {
	token := requireEnv(t, "BIOT_E2E_TOKEN")
	node := requireNode(t)
	env := newCLIEnv(t)
	env.writeConfig(t, serverURL(t), token)

	name := randomName(t, "resolve-")
	if result := env.run(t, nil, "create", "--repo", "https://github.com/example/resolve.git", "--name", name, "--node", node); result.exit != 0 {
		t.Fatalf("create exited %d:\n%s", result.exit, result.combined())
	}
	id := biotID(t, env, name)

	byName := env.run(t, nil, "show", name)
	byID := env.run(t, nil, "show", id)
	if byName.exit != 0 || byID.exit != 0 {
		t.Fatalf("show by name exited %d and by ID exited %d:\n%s\n%s", byName.exit, byID.exit, byName.combined(), byID.combined())
	}
	if !strings.Contains(byName.stdout, "id: "+id) || !strings.Contains(byID.stdout, "id: "+id) {
		t.Fatalf("name and ID did not resolve to %s:\n%s\n%s", id, byName.stdout, byID.stdout)
	}

	missing := env.run(t, nil, "show", "no-such-biot")
	if missing.exit == 0 {
		t.Fatalf("show of an unknown name should fail:\n%s", missing.combined())
	}
	if !strings.Contains(missing.combined(), "That Biot was not found.") {
		t.Fatalf("the not-found sentence did not reach the person:\n%s", missing.combined())
	}
}

// TestNodesListsTheConnectedNode proves the node view reflects the live peer.
func TestNodesListsTheConnectedNode(t *testing.T) {
	token := requireEnv(t, "BIOT_E2E_TOKEN")
	node := requireNode(t)
	env := newCLIEnv(t)
	env.writeConfig(t, serverURL(t), token)

	result := env.run(t, nil, "nodes")
	if result.exit != 0 {
		t.Fatalf("nodes exited %d:\n%s", result.exit, result.combined())
	}
	var row string
	for _, line := range strings.Split(result.stdout, "\n") {
		if strings.HasPrefix(line, node) {
			row = line
		}
	}
	if row == "" {
		t.Fatalf("nodes did not list the connected node %s:\n%s", node, result.stdout)
	}
	for _, field := range []string{"enabled", "ready", "aarch64-linux"} {
		if !strings.Contains(row, field) {
			t.Fatalf("the node row is missing %q:\n%s", field, row)
		}
	}
}

// TestTokenListAndRevoke revokes a second credential and proves it stops
// working, without touching the credential the rest of the suite uses.
func TestTokenListAndRevoke(t *testing.T) {
	token := requireEnv(t, "BIOT_E2E_TOKEN")
	secondToken := requireEnv(t, "BIOT_E2E_SECOND_TOKEN")
	secondID := requireEnv(t, "BIOT_E2E_SECOND_CREDENTIAL_ID")
	env := newCLIEnv(t)
	env.writeConfig(t, serverURL(t), token)

	list := env.run(t, nil, "token", "list")
	if list.exit != 0 {
		t.Fatalf("token list exited %d:\n%s", list.exit, list.combined())
	}
	if !strings.Contains(list.stdout, "second") || !strings.Contains(list.stdout, secondID) {
		t.Fatalf("token list did not show the second credential:\n%s", list.stdout)
	}

	revoke := env.run(t, nil, "token", "revoke", secondID)
	if revoke.exit != 0 {
		t.Fatalf("token revoke exited %d:\n%s", revoke.exit, revoke.combined())
	}
	if !strings.Contains(revoke.stdout, "revoked") {
		t.Fatalf("token revoke did not report success:\n%s", revoke.stdout)
	}

	revokedEnv := newCLIEnv(t)
	revokedEnv.writeConfig(t, serverURL(t), secondToken)
	after := revokedEnv.run(t, nil, "list")
	if after.exit == 0 {
		t.Fatalf("the revoked token still works:\n%s", after.combined())
	}
	if !strings.Contains(after.combined(), "Your session is no longer valid") {
		t.Fatalf("the revoked token did not get the unauthenticated sentence:\n%s", after.combined())
	}
}

// TestSSHKeyAddListRemove registers a freshly generated public key and removes
// it again.
func TestSSHKeyAddListRemove(t *testing.T) {
	token := requireEnv(t, "BIOT_E2E_TOKEN")
	env := newCLIEnv(t)
	env.writeConfig(t, serverURL(t), token)

	keyPath := filepath.Join(t.TempDir(), "e2e_key")
	keygen := exec.Command("ssh-keygen", "-t", "ed25519", "-N", "", "-f", keyPath, "-q")
	if output, err := keygen.CombinedOutput(); err != nil {
		t.Fatalf("ssh-keygen: %v\n%s", err, output)
	}

	add := env.run(t, nil, "ssh-key", "add", keyPath+".pub")
	if add.exit != 0 {
		t.Fatalf("ssh-key add exited %d:\n%s", add.exit, add.combined())
	}
	if !strings.Contains(add.stdout, "e2e_key.pub") || !strings.Contains(add.stdout, "SHA256:") {
		t.Fatalf("ssh-key add did not report the label and fingerprint:\n%s", add.stdout)
	}

	list := env.run(t, nil, "ssh-key", "list")
	if list.exit != 0 {
		t.Fatalf("ssh-key list exited %d:\n%s", list.exit, list.combined())
	}
	var id string
	for _, line := range strings.Split(list.stdout, "\n") {
		if strings.HasPrefix(line, "e2e_key.pub\t") {
			id = strings.Split(line, "\t")[1]
		}
	}
	if id == "" {
		t.Fatalf("ssh-key list did not show the key:\n%s", list.stdout)
	}

	remove := env.run(t, nil, "ssh-key", "rm", id)
	if remove.exit != 0 {
		t.Fatalf("ssh-key rm exited %d:\n%s", remove.exit, remove.combined())
	}
	if !strings.Contains(remove.stdout, "removed") {
		t.Fatalf("ssh-key rm did not report success:\n%s", remove.stdout)
	}
}

// TestShareGrantsUnshare grants shell and view access to a resolved principal,
// shows them, and removes them.
func TestShareGrantsUnshare(t *testing.T) {
	token := requireEnv(t, "BIOT_E2E_TOKEN")
	node := requireNode(t)
	email := requireEnv(t, "BIOT_E2E_SHARE_EMAIL")
	env := newCLIEnv(t)
	env.writeConfig(t, serverURL(t), token)

	name := randomName(t, "share-")
	if result := env.run(t, nil, "create", "--repo", "https://github.com/example/share.git", "--name", name, "--node", node); result.exit != 0 {
		t.Fatalf("create exited %d:\n%s", result.exit, result.combined())
	}

	if result := env.run(t, nil, "share", name, "--to", email, "--shell"); result.exit != 0 {
		t.Fatalf("share shell exited %d:\n%s", result.exit, result.combined())
	} else if !strings.Contains(result.stdout, "Shell access granted for "+email+".") {
		t.Fatalf("share shell did not report the grant:\n%s", result.stdout)
	}
	if result := env.run(t, nil, "publish", name, "3000"); result.exit != 0 {
		t.Fatalf("publish exited %d:\n%s", result.exit, result.combined())
	}
	if result := env.run(t, nil, "share", name, "--to", email, "--port", "3000"); result.exit != 0 {
		t.Fatalf("share view exited %d:\n%s", result.exit, result.combined())
	}

	grants := env.run(t, nil, "grants", name)
	if grants.exit != 0 {
		t.Fatalf("grants exited %d:\n%s", grants.exit, grants.combined())
	}
	if !strings.Contains(grants.stdout, "shell: "+email) {
		t.Fatalf("grants did not show the shell grant:\n%s", grants.stdout)
	}
	if !strings.Contains(grants.stdout, "view port 3000: "+email) {
		t.Fatalf("grants did not show the view grant:\n%s", grants.stdout)
	}

	if result := env.run(t, nil, "unshare", name, "--to", email, "--shell"); result.exit != 0 {
		t.Fatalf("unshare shell exited %d:\n%s", result.exit, result.combined())
	} else if !strings.Contains(result.stdout, "Shell access removed for "+email+".") {
		t.Fatalf("unshare shell did not report the removal:\n%s", result.stdout)
	}
	if result := env.run(t, nil, "unshare", name, "--to", email, "--port", "3000"); result.exit != 0 {
		t.Fatalf("unshare view exited %d:\n%s", result.exit, result.combined())
	}

	after := env.run(t, nil, "grants", name)
	if after.exit != 0 {
		t.Fatalf("grants after unshare exited %d:\n%s", after.exit, after.combined())
	}
	if !strings.Contains(after.stdout, "No explicit grants.") {
		t.Fatalf("grants still shows a grant after unshare:\n%s", after.stdout)
	}

	unknown := env.run(t, nil, "share", name, "--to", "nobody@example.test", "--shell")
	if unknown.exit == 0 {
		t.Fatalf("sharing with an unknown principal should fail:\n%s", unknown.combined())
	}
	if !strings.Contains(unknown.combined(), `That principal could not be found for "nobody@example.test".`) {
		t.Fatalf("the unknown-principal sentence did not reach the person:\n%s", unknown.combined())
	}
}

// TestLoginAndLogout covers the credential lifecycle the CLI owns locally.
func TestLoginAndLogout(t *testing.T) {
	token := requireEnv(t, "BIOT_E2E_TOKEN")
	env := newCLIEnv(t)

	notLoggedIn := env.run(t, nil, "list")
	if notLoggedIn.exit == 0 {
		t.Fatalf("list without a config should fail:\n%s", notLoggedIn.combined())
	}
	if !strings.Contains(notLoggedIn.combined(), "you are not logged in; run biot login") {
		t.Fatalf("the not-logged-in sentence did not reach the person:\n%s", notLoggedIn.combined())
	}

	login := env.run(t, []byte(token), "login", serverURL(t))
	if login.exit != 0 {
		t.Fatalf("login exited %d:\n%s", login.exit, login.combined())
	}
	if !strings.Contains(login.stdout, "Logged in as ") {
		t.Fatalf("login did not confirm the account:\n%s", login.stdout)
	}
	if result := env.run(t, nil, "list"); result.exit != 0 {
		t.Fatalf("list after login exited %d:\n%s", result.exit, result.combined())
	}

	logout := env.run(t, nil, "logout")
	if logout.exit != 0 {
		t.Fatalf("logout exited %d:\n%s", logout.exit, logout.combined())
	}
	if !strings.Contains(logout.stdout, "Logged out.") {
		t.Fatalf("logout did not confirm:\n%s", logout.stdout)
	}
	if result := env.run(t, nil, "list"); result.exit == 0 {
		t.Fatalf("list after logout should fail:\n%s", result.combined())
	}
}

// TestSSHCommand drives the whole shell path: the CLI resolves the Biot, asks
// the server for the SSH address, runs the real ssh client, the server opens a
// shell stream, and the peer serves it. It proves the command output and the
// exit status that travels back.
func TestSSHCommand(t *testing.T) {
	token := requireEnv(t, "BIOT_E2E_TOKEN")
	node := requireNode(t)
	env := newCLIEnv(t)
	env.writeConfig(t, serverURL(t), token)

	keyPath := filepath.Join(t.TempDir(), "id_ed25519")
	keygen := exec.Command("ssh-keygen", "-t", "ed25519", "-N", "", "-f", keyPath, "-q")
	if output, err := keygen.CombinedOutput(); err != nil {
		t.Fatalf("ssh-keygen: %v\n%s", err, output)
	}
	if add := env.run(t, nil, "ssh-key", "add", keyPath+".pub"); add.exit != 0 {
		t.Fatalf("ssh-key add exited %d:\n%s", add.exit, add.combined())
	}

	// ssh reads its user config from the passwd home and ignores $HOME, so the
	// only place to relax host-key checking for a fresh host key is a wrapper
	// on PATH. The wrapper only adds client policy; it still runs the real ssh.
	realSSH, err := exec.LookPath("ssh")
	if err != nil {
		t.Fatalf("find ssh: %v", err)
	}
	wrapperDir := filepath.Join(env.temp, "bin")
	if err := os.MkdirAll(wrapperDir, 0o755); err != nil {
		t.Fatalf("create wrapper dir: %v", err)
	}
	wrapper := "#!/bin/sh\nexec " + realSSH + " -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \"$@\"\n"
	if err := os.WriteFile(filepath.Join(wrapperDir, "ssh"), []byte(wrapper), 0o755); err != nil {
		t.Fatalf("write ssh wrapper: %v", err)
	}
	env.extra = append(env.extra, "PATH="+wrapperDir+":"+os.Getenv("PATH"))

	name := randomName(t, "ssh-")
	if result := env.run(t, nil, "create", "--repo", "https://github.com/example/ssh.git", "--name", name, "--node", node); result.exit != 0 {
		t.Fatalf("create exited %d:\n%s", result.exit, result.combined())
	}

	echo := env.run(t, nil, "ssh", name, "--identity", keyPath, "--", "echo", "hello")
	if echo.exit != 0 {
		t.Fatalf("ssh echo exited %d:\n%s", echo.exit, echo.combined())
	}
	if strings.TrimSpace(echo.stdout) != "hello" {
		t.Fatalf("ssh echo printed %q, want %q", echo.stdout, "hello")
	}

	failed := env.run(t, nil, "ssh", name, "--identity", keyPath, "--", "false")
	if failed.exit != 1 {
		t.Fatalf("ssh false exited %d, want the remote status 1:\n%s", failed.exit, failed.combined())
	}

	missing := env.run(t, nil, "ssh", name, "--identity", keyPath, "--", "ls")
	if missing.exit != 127 {
		t.Fatalf("ssh ls exited %d, want 127:\n%s", missing.exit, missing.combined())
	}
	if !strings.Contains(missing.stdout, "command not found") {
		t.Fatalf("ssh ls did not print the shell entry's refusal:\n%s", missing.combined())
	}
}

// biotID reads the ID the server assigned to a named Biot from list output.
func biotID(t *testing.T, env *cliEnv, name string) string {
	t.Helper()
	list := env.run(t, nil, "list")
	if list.exit != 0 {
		t.Fatalf("list exited %d:\n%s", list.exit, list.combined())
	}
	for _, line := range strings.Split(list.stdout, "\n") {
		fields := strings.Split(line, "\t")
		if len(fields) > 1 && fields[0] == name {
			return fields[1]
		}
	}
	t.Fatalf("list did not show %s:\n%s", name, list.stdout)
	return ""
}

// assertContainer waits for the node to report the container, because the command that changed it
// returned as soon as the server recorded the intent.
func assertContainer(t *testing.T, env *cliEnv, name string, want string) {
	t.Helper()
	waitForShow(t, env, name, "container: "+want)
}
