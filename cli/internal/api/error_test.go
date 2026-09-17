package api

import (
	"strings"
	"testing"
)

// The server sends one of these tags in every error body, plus "internal" when
// the body is not parseable. Every one must reach a person as a sentence, not a
// tag or a panic. The package init already panics on an unmapped tag; this test
// asserts the observable wording so a deliberate string edit cannot silently
// regress it.
func TestEveryCommandErrorTagProducesASentence(t *testing.T) {
	for _, tag := range commandErrorTags {
		message := (&Error{Tag: tag}).Error()
		if strings.TrimSpace(message) == "" {
			t.Errorf("tag %q produced no message", tag)
			continue
		}
		if strings.Contains(message, "\n") {
			t.Errorf("tag %q produced a multiline message: %q", tag, message)
		}
		if message == tag {
			t.Errorf("tag %q leaked as the whole message", tag)
		}
	}
}

func TestInternalErrorProducesASentence(t *testing.T) {
	message := (&Error{Tag: "internal"}).Error()
	if !strings.Contains(message, "could not complete") {
		t.Fatalf("internal error wording regressed: %q", message)
	}
}

func TestUnknownCommandErrorTagIsActionable(t *testing.T) {
	message := (&Error{Tag: "future_server_error"}).Error()
	if !strings.Contains(message, "Update biot and try again") {
		t.Fatalf("unknown tag should tell the person to update: %q", message)
	}
	if strings.TrimSpace(message) == "" {
		t.Fatal("unknown tag produced no message")
	}
}

func TestRevisionConflictNamesTheCurrentRevision(t *testing.T) {
	message := (&Error{Tag: "revision_conflict", CurrentRevision: 42}).Error()
	if !strings.Contains(message, "42") {
		t.Fatalf("revision conflict should name revision 42: %q", message)
	}
}

func TestEveryServerFieldReasonProducesWording(t *testing.T) {
	for _, reason := range serverFieldErrorReasons {
		message := reasonText(reason)
		if strings.TrimSpace(message) == "" {
			t.Errorf("field reason %q produced no wording", reason)
			continue
		}
		if strings.Contains(message, "unknown validation reason") {
			t.Errorf("field reason %q fell through to the unknown fallback: %q", reason, message)
		}
	}
}

func TestUnknownFieldReasonIsActionable(t *testing.T) {
	message := reasonText("future_server_reason")
	if !strings.Contains(message, "unknown validation reason") {
		t.Fatalf("unknown field reason should say so: %q", message)
	}
	if !strings.Contains(message, "update biot") {
		t.Fatalf("unknown field reason should tell the person to update: %q", message)
	}
}

func TestInvalidInputMessageIsDeterministic(t *testing.T) {
	fields := map[string][]string{
		"name":    {"missing"},
		"node_id": {"no_default_node"},
	}
	message := invalidInputMessage(fields)
	if !strings.HasPrefix(message, "name is required.; node_id has no default node") {
		t.Fatalf("field errors should be sorted by field name: %q", message)
	}
}

func TestInvalidInputMessageWithoutFieldsStillSpeaks(t *testing.T) {
	message := invalidInputMessage(nil)
	if !strings.Contains(message, "invalid input") {
		t.Fatalf("empty field errors should still produce a sentence: %q", message)
	}
}

func TestSecretJSONValueRejectsInvalidUTF8(t *testing.T) {
	if _, err := secretJSONValue([]byte{0x61, 0xff, 0xfe, 0x62}); err == nil {
		t.Fatal("invalid UTF-8 should be rejected")
	} else if !strings.Contains(err.Error(), "valid UTF-8") {
		t.Fatalf("invalid-UTF-8 error should name the constraint: %v", err)
	}
}

func TestSecretJSONValuePreservesValidBytes(t *testing.T) {
	value := []byte("alpha\nbeta\x00gamma")
	encoded, err := secretJSONValue(value)
	if err != nil {
		t.Fatalf("valid UTF-8 rejected: %v", err)
	}
	if encoded != string(value) {
		t.Fatalf("valid UTF-8 was changed: %q", encoded)
	}
}
