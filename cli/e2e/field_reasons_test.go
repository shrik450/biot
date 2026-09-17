//go:build e2e

package e2e

import (
	"strings"
	"testing"
)

// TestTooLongNameReachesThePerson drives the real server's name_too_long reason,
// which BiotName.parse/1 now emits for a well-formed name over 63 bytes.
func TestTooLongNameReachesThePerson(t *testing.T) {
	token := requireEnv(t, "BIOT_E2E_TOKEN")
	node := requireNode(t)
	env := newCLIEnv(t)
	env.writeConfig(t, serverURL(t), token)

	name := strings.Repeat("a", 64)
	result := env.run(t, nil, "create", "--repo", "https://github.com/example/toolong.git", "--name", name, "--node", node)
	if result.exit == 0 {
		t.Fatalf("a 64-byte name should be refused:\n%s", result.combined())
	}
	if !strings.Contains(result.combined(), "name is longer than 63 characters; shorten it.") {
		t.Fatalf("the name_too_long sentence did not reach the person:\n%s", result.combined())
	}
	if strings.Contains(result.combined(), "unknown validation reason") {
		t.Fatalf("the name_too_long reason fell through to the fallback:\n%s", result.combined())
	}
}

// TestReservedSecretNameReachesThePerson drives a real server field reason
// through the real binary: HOME is reserved by the launcher, so the server
// rejects it as a secret name with the reserved_name reason.
func TestReservedSecretNameReachesThePerson(t *testing.T) {
	token := requireEnv(t, "BIOT_E2E_TOKEN")
	node := requireNode(t)
	env := newCLIEnv(t)
	env.writeConfig(t, serverURL(t), token)

	name := randomName(t, "reserved-")
	if result := env.run(t, nil, "create", "--repo", "https://github.com/example/reserved.git", "--name", name, "--node", node); result.exit != 0 {
		t.Fatalf("create exited %d:\n%s", result.exit, result.combined())
	}

	result := env.run(t, []byte("value"), "secret", "set", name, "HOME", "--stdin")
	if result.exit == 0 {
		t.Fatalf("a reserved secret name should be refused:\n%s", result.combined())
	}
	if !strings.Contains(result.combined(), "name is reserved; choose another name.") {
		t.Fatalf("the reserved_name sentence did not reach the person:\n%s", result.combined())
	}
	if strings.Contains(result.combined(), "unknown validation reason") {
		t.Fatalf("the reserved_name reason fell through to the fallback:\n%s", result.combined())
	}
}

// TestNoDefaultNodeReachesThePerson drives the real server's no_default_node
// reason: the dev server has no default node, so create without --node is
// refused with the field named.
func TestNoDefaultNodeReachesThePerson(t *testing.T) {
	token := requireEnv(t, "BIOT_E2E_TOKEN")
	env := newCLIEnv(t)
	env.writeConfig(t, serverURL(t), token)

	name := randomName(t, "nodefault-")
	result := env.run(t, nil, "create", "--repo", "https://github.com/example/nodefault.git", "--name", name)
	if result.exit == 0 {
		t.Fatalf("create without --node should be refused when the server has no default:\n%s", result.combined())
	}
	if !strings.Contains(result.combined(), "node_id is required because the server has no default node; choose one.") {
		t.Fatalf("the no_default_node sentence did not reach the person:\n%s", result.combined())
	}
	if strings.Contains(result.combined(), "unknown validation reason") {
		t.Fatalf("the no_default_node reason fell through to the fallback:\n%s", result.combined())
	}
}
