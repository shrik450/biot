package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"testing"
)

// fieldReasonSentences is the user-visible contract: the sentence a person
// reads when the server rejects a field for each reason it can name. It is
// written out here rather than read from the embedded vocabulary so an edit to
// the artifact cannot silently change what a person sees without failing this
// test. Each entry is the rendered sentence, after any client remedy.
var fieldReasonSentences = map[string]string{
	"missing":                 "is required.",
	"invalid_format":          "has an invalid format.",
	"out_of_range":            "is outside the allowed range.",
	"name_too_long":           "is longer than 63 characters; shorten it.",
	"invalid_value":           "has an invalid value.",
	"reserved_name":           "is reserved; choose another name.",
	"no_default_node":         "is required because the server has no default node; choose one.",
	"already_registered":      "is already registered; use a different key.",
	"not_future":              "must be in the future; choose a later time.",
	"too_far":                 "is beyond the allowed lifetime; choose an earlier time.",
	"unknown_principal":       "does not identify a known principal; check the email address.",
	"publication_not_active":  "is no longer active; choose an active publication.",
	"not_ready":               "is not ready yet.",
	"nul_byte":                "must not contain a NUL byte.",
	"secret_value_too_large":  "is larger than 65536 bytes; shorten it.",
	"too_many_layers":         "has more than 16 layers; remove one.",
	"repository_url_too_long": "is longer than 2048 characters; shorten it.",
	"source_ref_too_long":     "is longer than 256 characters; shorten it.",
	"embedded_credentials":    "must not embed credentials; deliver them as a source-fetch credential instead.",
}

// invalidInputServer answers every request with the exact error body the real
// server builds for one rejected field: a 422 whose `fields` map carries the
// reason. Nothing here reaches into the client; the client only sees HTTP.
func invalidInputServer(t *testing.T, field string, reason string) *httptest.Server {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		response.Header().Set("Content-Type", "application/json")
		response.WriteHeader(http.StatusUnprocessableEntity)
		_ = json.NewEncoder(response).Encode(map[string]any{
			"error":  "invalid_input",
			"fields": map[string][]string{field: {reason}},
		})
	}))
	t.Cleanup(server.Close)
	return server
}

// TestErrorVocabularyArtifactAgreesWithTheVocabulary reads the committed
// artifact through go:embed and checks it against the vocabulary the client
// actually uses. go:embed is deliberate: the test binary stays self-contained,
// it does not depend on the working directory, and a missing artifact fails the
// build rather than a test run.
func TestErrorVocabularyArtifactAgreesWithTheVocabulary(t *testing.T) {
	if !strings.HasSuffix(vocabularyFile, "\n") {
		t.Fatal("the artifact must end with a newline")
	}
	lines := strings.Split(strings.TrimSuffix(vocabularyFile, "\n"), "\n")
	if len(lines) == 0 || lines[0] == "" {
		t.Fatal("the artifact must not be empty")
	}
	previous := ""
	for index, line := range lines {
		parts := strings.Split(line, "|")
		if len(parts) != 5 || parts[0] == "" || parts[1] == "" || parts[3] == "" {
			t.Fatalf("artifact line %d is malformed: %q", index, line)
		}
		if parts[0] <= previous {
			t.Fatalf("the artifact is not sorted and unique: %q follows %q", parts[0], previous)
		}
		previous = parts[0]
	}
	if len(vocabulary) != len(lines) {
		t.Fatalf("the parsed vocabulary has %d entries and the artifact has %d lines", len(vocabulary), len(lines))
	}
	if len(serverFieldErrorReasons) != len(fieldReasonSentences) {
		t.Fatalf("the client lists %d field reasons and the golden table has %d", len(serverFieldErrorReasons), len(fieldReasonSentences))
	}
	for _, reason := range serverFieldErrorReasons {
		entry, ok := vocabulary[reason]
		if !ok || entry.kind != "field" {
			t.Fatalf("field reason %q is missing from the vocabulary", reason)
		}
		if strings.TrimSpace(entry.sentence) == "" {
			t.Errorf("the artifact names %q but the sentence is empty", reason)
		}
		if _, known := fieldReasonSentences[reason]; !known {
			t.Errorf("field reason %q has no entry in the golden table", reason)
		}
	}
}

// TestEveryServerFieldReasonReachesAPerson drives each reason the server can
// send through a real HTTP response and checks the sentence a person reads.
// The message must name the field, carry the reason's own wording, and never
// fall through to the unknown-reason fallback.
func TestEveryServerFieldReasonReachesAPerson(t *testing.T) {
	for reason, want := range fieldReasonSentences {
		t.Run(reason, func(t *testing.T) {
			server := invalidInputServer(t, "name", reason)
			client, err := New(server.URL, "token", nil)
			if err != nil {
				t.Fatalf("build client: %v", err)
			}
			_, err = client.ListBiots(context.Background())
			if err == nil {
				t.Fatal("the server rejected the request but the client returned no error")
			}
			message := err.Error()
			if !strings.HasPrefix(message, "name ") {
				t.Fatalf("the message should name the rejected field: %q", message)
			}
			if !strings.Contains(message, want) {
				t.Fatalf("reason %q rendered %q, want it to contain %q", reason, message, want)
			}
			if strings.Contains(message, "unknown validation reason") {
				t.Fatalf("reason %q fell through to the fallback: %q", reason, message)
			}
			if strings.Contains(message, reason) {
				t.Fatalf("reason %q leaked its wire name instead of a sentence: %q", reason, message)
			}
		})
	}
}

// TestTheRenderingContractCoversEveryServerReason fails when the server gains a
// reason this test does not know about, so the contract cannot silently fall
// behind the vocabulary.
func TestTheRenderingContractCoversEveryServerReason(t *testing.T) {
	for _, reason := range serverFieldErrorReasons {
		if _, known := fieldReasonSentences[reason]; !known {
			t.Errorf("server reason %q has no entry in the rendering contract", reason)
		}
	}
	if len(fieldReasonSentences) != len(serverFieldErrorReasons) {
		t.Fatalf("the contract has %d reasons and the client lists %d", len(fieldReasonSentences), len(serverFieldErrorReasons))
	}
}

// TestUnknownFieldReasonUsesTheFallback proves the CLI's fallback exists, so
// the "never the fallback" assertion above is meaningful rather than vacuous.
// The CLI is a separate binary that can meet a newer server, unlike the web UI,
// which ships with the server and raises on an unknown reason.
func TestUnknownFieldReasonUsesTheFallback(t *testing.T) {
	server := invalidInputServer(t, "name", "future_server_reason")
	client, err := New(server.URL, "token", nil)
	if err != nil {
		t.Fatalf("build client: %v", err)
	}
	_, err = client.ListBiots(context.Background())
	if err == nil {
		t.Fatal("the server rejected the request but the client returned no error")
	}
	message := err.Error()
	if !strings.Contains(message, `unknown validation reason "future_server_reason"`) {
		t.Fatalf("an unknown reason should say so: %q", message)
	}
	if !strings.Contains(message, "update biot and try again") {
		t.Fatalf("an unknown reason should tell the person to update: %q", message)
	}
}

// TestFieldReasonsUseCommasAndFieldsUseSemicolons checks the wire shape with
// more than one field and more than one reason on a field.
func TestFieldReasonsUseCommasAndFieldsUseSemicolons(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		response.Header().Set("Content-Type", "application/json")
		response.WriteHeader(http.StatusUnprocessableEntity)
		_ = json.NewEncoder(response).Encode(map[string]any{
			"error": "invalid_input",
			"fields": map[string][]string{
				"node_id": {"no_default_node"},
				"name":    {"missing", "reserved_name"},
			},
		})
	}))
	t.Cleanup(server.Close)

	client, err := New(server.URL, "token", nil)
	if err != nil {
		t.Fatalf("build client: %v", err)
	}
	_, err = client.ListBiots(context.Background())
	if err == nil {
		t.Fatal("the server rejected the request but the client returned no error")
	}
	want := "name is required., name is reserved; choose another name.; node is required because the server has no default node; choose one."
	if err.Error() != want {
		t.Fatalf("rendered %q, want %q", err.Error(), want)
	}
}

// TestTwoFieldsKeepMultipleReasonsTogether catches the case where each field
// has its own sentence but the renderer loses the field grouping when one field
// carries more than one reason.
func TestTwoFieldsKeepMultipleReasonsTogether(t *testing.T) {
	fields := map[string][]string{
		"name":       {"missing"},
		"repository": {"invalid_format", "repository_url_too_long"},
	}

	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		response.Header().Set("Content-Type", "application/json")
		response.WriteHeader(http.StatusUnprocessableEntity)
		_ = json.NewEncoder(response).Encode(map[string]any{"error": "invalid_input", "fields": fields})
	}))
	t.Cleanup(server.Close)

	client, err := New(server.URL, "token", nil)
	if err != nil {
		t.Fatalf("build client: %v", err)
	}
	_, err = client.ListBiots(context.Background())
	if err == nil {
		t.Fatal("the server rejected the request but the client returned no error")
	}
	want := "name is required.; repository has an invalid format., repository is longer than 2048 characters; shorten it."
	if err.Error() != want {
		t.Fatalf("rendered %q, want %q", err.Error(), want)
	}
}

// TestMultiFieldOrderMatchesTheServerLabels proves the CLI renders a multi-field
// validation error exactly as the server does: ordered by the server's rendered
// label and joined with "; ". The single-reason tests read the server-generated
// error_vocabulary.txt through go:embed; this extends the same embedded-artifact
// method to a multi-field case, using field_labels.txt for the labels and
// error_vocabulary.txt for the sentences. The composition rule is restated here
// because the artifacts carry the data, not the rule.
//
// Wire order is id, kind, node_id, public_key; label order is grant, id, node,
// public key, so kind and id swap. The old client sorted by wire name and would
// have rendered id first, so this case discriminates the two orders.
func TestMultiFieldOrderMatchesTheServerLabels(t *testing.T) {
	fields := map[string][]string{
		"id":         {"missing"},
		"kind":       {"invalid_format"},
		"node_id":    {"no_default_node"},
		"public_key": {"already_registered"},
	}

	order := []string{"id", "kind", "node_id", "public_key"}
	sort.Slice(order, func(left, right int) bool {
		return fieldLabels[order[left]] < fieldLabels[order[right]]
	})
	if order[0] != "kind" || order[1] != "id" {
		t.Fatalf("this test needs the label order to differ from the wire order, got %v", order)
	}

	want := make([]string, 0, len(order))
	for _, field := range order {
		for _, reason := range fields[field] {
			entry, ok := vocabulary[reason]
			if !ok || entry.kind != "field" {
				t.Fatalf("reason %q is not a field reason", reason)
			}
			if _, hasRemedy := clientRemedies[reason]; hasRemedy {
				t.Fatalf("reason %q carries a remedy, so this test cannot derive its sentence from the artifact", reason)
			}
			want = append(want, fieldLabels[field]+" "+entry.sentence)
		}
	}
	expected := strings.Join(want, "; ")

	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		response.Header().Set("Content-Type", "application/json")
		response.WriteHeader(http.StatusUnprocessableEntity)
		_ = json.NewEncoder(response).Encode(map[string]any{"error": "invalid_input", "fields": fields})
	}))
	t.Cleanup(server.Close)

	client, err := New(server.URL, "token", nil)
	if err != nil {
		t.Fatalf("build client: %v", err)
	}
	_, err = client.ListBiots(context.Background())
	if err == nil {
		t.Fatal("the server rejected the request but the client returned no error")
	}
	if got := err.Error(); got != expected {
		t.Fatalf("rendered %q, want the server's rendering %q", got, expected)
	}
}

// TestFieldLabelArtifactIsWellFormed reads the server-generated field_labels.txt
// through go:embed. The server refuses to compile when two fields share a label,
// so the label is a total order; the client relies on that to sort a multi-field
// error. This checks the artifact carries one distinct label per field.
func TestFieldLabelArtifactIsWellFormed(t *testing.T) {
	if !strings.HasSuffix(fieldLabelsFile, "\n") {
		t.Fatal("the label artifact must end with a newline")
	}
	lines := strings.Split(strings.TrimSuffix(fieldLabelsFile, "\n"), "\n")
	if len(lines) == 0 || lines[0] == "" {
		t.Fatal("the label artifact must not be empty")
	}
	previous := ""
	labels := make(map[string]string, len(lines))
	for index, line := range lines {
		parts := strings.Split(line, "|")
		if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
			t.Fatalf("label artifact line %d is malformed: %q", index, line)
		}
		if parts[0] <= previous {
			t.Fatalf("the label artifact is not sorted and unique: %q follows %q", parts[0], previous)
		}
		previous = parts[0]
		labels[parts[0]] = parts[1]
	}
	if len(labels) != len(lines) {
		t.Fatalf("the parsed labels have %d entries and the artifact has %d lines", len(labels), len(lines))
	}
	seen := make(map[string]string, len(labels))
	for field, label := range labels {
		if other, ok := seen[label]; ok {
			t.Errorf("fields %q and %q share the label %q; the server refuses duplicate labels", field, other, label)
		}
		seen[label] = field
	}
}
