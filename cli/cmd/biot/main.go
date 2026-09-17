package main

import (
	"errors"
	"fmt"
	"os"
	"sort"

	"github.com/shrik450/biot/cli/internal/command"
)

var rootCommand = &command.Command{
	Name:        "biot",
	Synopsis:    "biot <command> [options]",
	Description: "Biot provides development environments managed through a Biot server. Start with: biot login SERVER_URL",
	Options:     "  -h, --help       Show this help.\n  --version        Show the client version.",
	Run: func(context command.Context, arguments []string) error {
		if err := command.RejectUnknown(arguments, "--version"); err != nil {
			return fmt.Errorf("%w; run biot --help", err)
		}
		if len(arguments) == 1 && arguments[0] == "--version" {
			_, err := fmt.Fprintln(context.Stdout, "biot "+clientVersion)
			return err
		}
		return errors.New("run biot --help for available commands")
	},
}

const clientVersion = "dev"

var commandOrderNames = map[string]int{
	"login": 0, "logout": 1, "list": 2, "show": 3,
	"create": 4, "start": 5, "stop": 6, "restart": 7, "rebuild": 8, "destroy": 9, "wait": 10,
	"publish": 11, "unpublish": 12, "urls": 13, "share": 14, "unshare": 15, "grants": 16,
	"secret": 17, "fetch-credential": 18,
	"ssh": 19, "ssh-key": 20, "token": 21, "nodes": 22, "diagnose": 23, "logs": 24,
}

type exitStatusError struct{ status int }

func (e *exitStatusError) Error() string { return "remote command exited" }

func main() {
	sort.SliceStable(rootCommand.Children, func(left int, right int) bool {
		return commandOrder(rootCommand.Children[left].Name) < commandOrder(rootCommand.Children[right].Name)
	})
	context := command.Context{Stdout: os.Stdout, Stderr: os.Stderr}
	if err := rootCommand.Execute(context, os.Args[1:]); err != nil {
		if err == command.ErrHelp {
			return
		}
		var statusError *exitStatusError
		if errors.As(err, &statusError) {
			os.Exit(statusError.status)
		}
		fmt.Fprintln(context.Stderr, err)
		os.Exit(1)
	}
}

func commandOrder(name string) int {
	if order, ok := commandOrderNames[name]; ok {
		return order
	}
	return 1000
}

func validateArguments(commandName string, arguments []string, count int, allowed ...string) error {
	if err := rejectUnknown(commandName, arguments, allowed...); err != nil {
		return err
	}
	return command.RequireArguments(commandName, arguments, count)
}

func rejectUnknown(commandName string, arguments []string, allowed ...string) error {
	if err := command.RejectUnknown(arguments, allowed...); err != nil {
		return fmt.Errorf("%w; run biot %s --help", err, commandName)
	}
	return nil
}
