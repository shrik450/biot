package main

import (
	"strings"
	"testing"

	"github.com/shrik450/biot/cli/internal/command"
)

// The model's command table. Every row must be reachable from the root, and
// every leaf must be runnable and describe itself.
var declaredCommands = map[string][]string{
	"login":            {},
	"logout":           {},
	"list":             {},
	"show":             {},
	"create":           {},
	"start":            {},
	"stop":             {},
	"restart":          {},
	"rebuild":          {},
	"destroy":          {},
	"wait":             {},
	"publish":          {},
	"unpublish":        {},
	"urls":             {},
	"share":            {},
	"unshare":          {},
	"grants":           {},
	"secret":           {"set", "rm", "list"},
	"fetch-credential": {"set", "rm"},
	"ssh":              {},
	"ssh-key":          {"add", "list", "rm"},
	"token":            {"create", "list", "revoke"},
	"nodes":            {},
	"diagnose":         {},
	"logs":             {},
}

func findCommand(root *command.Command, path ...string) *command.Command {
	current := root
	for _, name := range path {
		var next *command.Command
		for _, child := range current.Children {
			if child.Name == name {
				next = child
				break
			}
		}
		if next == nil {
			return nil
		}
		current = next
	}
	return current
}

func TestEveryDeclaredCommandIsReachable(t *testing.T) {
	for name, children := range declaredCommands {
		if findCommand(rootCommand, name) == nil {
			t.Errorf("command %q is missing from the tree", name)
			continue
		}
		for _, child := range children {
			if findCommand(rootCommand, name, child) == nil {
				t.Errorf("subcommand %s %s is missing from the tree", name, child)
			}
		}
	}
}

func TestEveryCommandAndSubcommandDescribesItself(t *testing.T) {
	var walk func(path []string, cmd *command.Command)
	walk = func(path []string, cmd *command.Command) {
		label := strings.Join(append(path, cmd.Name), " ")
		if strings.TrimSpace(cmd.Synopsis) == "" {
			t.Errorf("%s has no synopsis", label)
		}
		if strings.TrimSpace(cmd.Description) == "" {
			t.Errorf("%s has no description", label)
		}
		if len(cmd.Children) == 0 {
			if cmd.Run == nil {
				t.Errorf("%s is a leaf with no Run function", label)
			}
			return
		}
		seen := make(map[string]bool)
		for _, child := range cmd.Children {
			if seen[child.Name] {
				t.Errorf("%s declares child %q twice", label, child.Name)
			}
			seen[child.Name] = true
			walk(append(path, cmd.Name), child)
		}
	}
	walk(nil, rootCommand)
}

func TestEveryCommandHelpRendersItsSynopsis(t *testing.T) {
	var walk func(path []string, cmd *command.Command)
	walk = func(path []string, cmd *command.Command) {
		var out strings.Builder
		if err := cmd.Help(command.Context{Stdout: &out, Stderr: &out}, nil); err != nil {
			t.Errorf("help for %s failed: %v", strings.Join(path, " "), err)
		}
		if !strings.Contains(out.String(), cmd.Synopsis) {
			t.Errorf("help for %s does not contain its synopsis %q:\n%s", strings.Join(path, " "), cmd.Synopsis, out.String())
		}
		for _, child := range cmd.Children {
			walk(append(path, cmd.Name), child)
		}
	}
	walk(nil, rootCommand)
}

func TestRootHelpListsEveryTopLevelCommand(t *testing.T) {
	var out strings.Builder
	if err := rootCommand.Help(command.Context{Stdout: &out, Stderr: &out}, nil); err != nil {
		t.Fatalf("root help failed: %v", err)
	}
	for name := range declaredCommands {
		if !strings.Contains(out.String(), name) {
			t.Errorf("root help does not list %q", name)
		}
	}
}
