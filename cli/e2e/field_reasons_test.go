//go:build e2e

package e2e

import (
	"strings"
	"testing"

	"github.com/shrik450/biot/cli/internal/api"
)

// assertReasonReachedThePerson checks that a rejected field reached the person in the client's own
// wording: the label from field_labels.txt and the sentence from error_vocabulary.txt, composed by
// the same function the CLI's own local guards use. Deriving both from the embedded artifacts is
// the point. This test once spelled the wire key `node_id` where the client renders the label
// `node`, and it sat broken until someone ran the suite; a hand-written sentence drifts the same
// way.
func assertReasonReachedThePerson(t *testing.T, result cliResult, field string, reason string) {
	t.Helper()
	want := api.FieldReasonMessage(field, reason)

	if !strings.Contains(result.combined(), want) {
		t.Fatalf("the %s reason did not reach the person as %q:\n%s", reason, want, result.combined())
	}
	// The client's fallback names the reason it does not know, in words the api package's own
	// TestUnknownFieldReasonUsesTheFallback guards.
	if strings.Contains(result.combined(), "unknown validation reason") {
		t.Fatalf("the %s reason fell through to the client's fallback:\n%s", reason, result.combined())
	}
}

// TestTooLongNameReachesThePerson drives the real server's name_too_long reason, which
// BiotName.parse/1 emits for a well-formed name over its limit. The name is one byte past the limit
// the vocabulary carries, so a changed limit cannot make this test pass vacuously.
func TestTooLongNameReachesThePerson(t *testing.T) {
	token := requireEnv(t, "BIOT_E2E_TOKEN")
	node := requireNode(t)
	env := newCLIEnv(t)
	env.writeConfig(t, serverURL(t), token)

	limit, ok := api.FieldReasonLimit("name_too_long")
	if !ok {
		t.Fatal("the vocabulary carries no name_too_long limit")
	}
	name := strings.Repeat("a", limit+1)

	result := env.run(t, nil, "create", "--repo", "https://github.com/example/toolong.git", "--name", name, "--node", node)
	if result.exit == 0 {
		t.Fatalf("a %d-byte name should be refused:\n%s", limit+1, result.combined())
	}
	assertReasonReachedThePerson(t, result, "name", "name_too_long")
}

// TestReservedSecretNameReachesThePerson drives a real server field reason through the real binary:
// HOME is reserved by the launcher, so the server rejects it as a secret name.
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
	assertReasonReachedThePerson(t, result, "name", "reserved_name")
}

// TestNoDefaultNodeReachesThePerson drives the real server's no_default_node reason: the dev server
// has no default node, so create without --node is refused with the field named.
func TestNoDefaultNodeReachesThePerson(t *testing.T) {
	token := requireEnv(t, "BIOT_E2E_TOKEN")
	env := newCLIEnv(t)
	env.writeConfig(t, serverURL(t), token)

	name := randomName(t, "nodefault-")
	result := env.run(t, nil, "create", "--repo", "https://github.com/example/nodefault.git", "--name", name)
	if result.exit == 0 {
		t.Fatalf("create without --node should be refused when the server has no default:\n%s", result.combined())
	}
	assertReasonReachedThePerson(t, result, "node_id", "no_default_node")
}
