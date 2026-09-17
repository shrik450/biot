package command

import (
	"errors"
	"strings"
	"testing"
)

func render(t *testing.T, c *Command) string {
	t.Helper()
	var out strings.Builder
	context := Context{Stdout: &out, Stderr: &out}
	if err := c.Help(context, nil); err != nil {
		t.Fatalf("Help(%s) returned error: %v", c.Name, err)
	}
	return out.String()
}

func TestHelpRendersEveryDeclaredField(t *testing.T) {
	leaf := &Command{
		Name:        "leaf",
		Synopsis:    "biot leaf ARG",
		Description: "Do the leaf thing.",
		Options:     "  --flag    Flip it.",
		Run:         func(Context, []string) error { return nil },
	}
	output := render(t, leaf)
	for _, wanted := range []string{
		"Usage: biot leaf ARG",
		"Do the leaf thing.",
		"Options:",
		"--flag",
		"Flip it.",
	} {
		if !strings.Contains(output, wanted) {
			t.Errorf("leaf help is missing %q:\n%s", wanted, output)
		}
	}
	if strings.Contains(output, "Commands:") {
		t.Errorf("leaf help should not list a Commands section:\n%s", output)
	}
}

func TestHelpListsChildrenInDeclaredOrder(t *testing.T) {
	group := &Command{
		Name:        "group",
		Synopsis:    "biot group <one|two>",
		Description: "A group.",
		Children: []*Command{
			{Name: "one", Synopsis: "biot group one", Description: "First."},
			{Name: "two", Synopsis: "biot group two", Description: "Second."},
		},
	}
	output := render(t, group)
	first := strings.Index(output, "one")
	second := strings.Index(output, "two")
	if first < 0 || second < 0 || first > second {
		t.Fatalf("children are not listed in order:\n%s", output)
	}
	if !strings.Contains(output, "Commands:") {
		t.Fatalf("group help is missing a Commands section:\n%s", output)
	}
}

func TestExecuteDispatchesToChildAndPassesRemainingArguments(t *testing.T) {
	var got []string
	child := &Command{Name: "child", Run: func(_ Context, arguments []string) error {
		got = append([]string(nil), arguments...)
		return nil
	}}
	root := &Command{Name: "root", Children: []*Command{child}}
	if err := root.Execute(Context{}, []string{"child", "a", "b"}); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if strings.Join(got, ",") != "a,b" {
		t.Fatalf("child received %v, want [a b]", got)
	}
}

func TestExecuteHelpShortCircuitsTheCommand(t *testing.T) {
	ran := false
	child := &Command{Name: "child", Synopsis: "biot child", Run: func(Context, []string) error {
		ran = true
		return nil
	}}
	root := &Command{Name: "root", Children: []*Command{child}}
	var out strings.Builder
	if err := root.Execute(Context{Stdout: &out, Stderr: &out}, []string{"child", "--help"}); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if ran {
		t.Fatal("the command ran even though --help was requested")
	}
	if !strings.Contains(out.String(), "biot child") {
		t.Fatalf("nested help was not printed:\n%s", out.String())
	}
}

func TestExecuteUnknownCommandNamesTheCommandAndHelp(t *testing.T) {
	root := &Command{Name: "root", Children: []*Command{{Name: "child"}}}
	err := root.Execute(Context{}, []string{"nope"})
	if err == nil {
		t.Fatal("expected an error for an unknown command")
	}
	for _, wanted := range []string{`"nope"`, "root --help"} {
		if !strings.Contains(err.Error(), wanted) {
			t.Errorf("unknown-command error is missing %q: %v", wanted, err)
		}
	}
}

func TestExecuteWithoutArgumentsOnGroupPrintsHelp(t *testing.T) {
	root := &Command{Name: "root", Children: []*Command{{Name: "child"}}}
	var out strings.Builder
	if err := root.Execute(Context{Stdout: &out, Stderr: &out}, nil); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if !strings.Contains(out.String(), "Commands:") {
		t.Fatalf("a group with no arguments should print its help:\n%s", out.String())
	}
}

func TestRequireArgumentsCountsExactly(t *testing.T) {
	if err := RequireArguments("show", []string{"a"}, 1); err != nil {
		t.Fatalf("one argument should satisfy a count of one: %v", err)
	}
	err := RequireArguments("show", []string{"a", "b"}, 1)
	if err == nil {
		t.Fatal("expected an error for too many arguments")
	}
	if !strings.Contains(err.Error(), "1 argument") {
		t.Errorf("argument-count error should name the count: %v", err)
	}
}

func TestRejectUnknownNamesTheOption(t *testing.T) {
	if err := RejectUnknown([]string{"--known", "positional"}, "--known"); err != nil {
		t.Fatalf("a known option should be accepted: %v", err)
	}
	err := RejectUnknown([]string{"--mystery"}, "--known")
	if err == nil {
		t.Fatal("expected an error for an unknown option")
	}
	if !strings.Contains(err.Error(), "--mystery") {
		t.Errorf("unknown-option error should name the option: %v", err)
	}
}

func TestHelpSurfacesWriteErrors(t *testing.T) {
	broken := writerFunc(func([]byte) (int, error) { return 0, errors.New("write failed") })
	command := &Command{Name: "root", Synopsis: "biot", Description: "d", Options: "o", Children: []*Command{{Name: "child"}}}
	if err := command.Help(Context{Stdout: broken}, nil); err == nil {
		t.Fatal("expected Help to surface a write error")
	}
}

type writerFunc func([]byte) (int, error)

func (f writerFunc) Write(value []byte) (int, error) { return f(value) }
