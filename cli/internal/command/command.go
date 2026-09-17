package command

import (
	"errors"
	"fmt"
	"io"
	"strings"
)

var ErrHelp = errors.New("help requested")

type Context struct {
	Stdout io.Writer
	Stderr io.Writer
}

type Command struct {
	Name        string
	Synopsis    string
	Description string
	Options     string
	Run         func(Context, []string) error
	Children    []*Command
}

func (c *Command) Execute(context Context, arguments []string) error {
	if len(arguments) == 0 {
		if len(c.Children) > 0 {
			return c.Help(context, nil)
		}
		return c.Run(context, arguments)
	}

	if arguments[0] == "--help" || arguments[0] == "-h" {
		return c.Help(context, arguments[1:])
	}
	if strings.HasPrefix(arguments[0], "-") {
		if c.Run != nil {
			return c.Run(context, arguments)
		}
		return fmt.Errorf("unknown flag %q; run biot %s --help", arguments[0], c.Name)
	}
	for _, child := range c.Children {
		if child.Name == arguments[0] {
			return child.Execute(context, arguments[1:])
		}
	}
	if len(c.Children) > 0 {
		return fmt.Errorf("unknown command %q; run %s --help", arguments[0], c.Name)
	}
	return c.Run(context, arguments)
}

func (c *Command) Help(context Context, _ []string) error {
	if _, err := fmt.Fprintf(context.Stdout, "Usage: %s", c.Synopsis); err != nil {
		return err
	}
	if c.Description != "" {
		if _, err := fmt.Fprintf(context.Stdout, "\n\n%s", c.Description); err != nil {
			return err
		}
	}
	if c.Options != "" {
		if _, err := fmt.Fprintf(context.Stdout, "\n\nOptions:\n%s", c.Options); err != nil {
			return err
		}
	}
	if len(c.Children) > 0 {
		if _, err := io.WriteString(context.Stdout, "\n\nCommands:\n"); err != nil {
			return err
		}
		for _, child := range c.Children {
			if _, err := fmt.Fprintf(context.Stdout, "  %-20s %s\n", child.Name, child.Description); err != nil {
				return err
			}
		}
	}
	_, err := io.WriteString(context.Stdout, "\n")
	return err
}

func RequireArguments(commandName string, arguments []string, count int) error {
	if len(arguments) != count {
		return fmt.Errorf("%s expects %d argument%s; run biot %s --help", commandName, count, plural(count), commandName)
	}
	return nil
}

func RejectUnknown(arguments []string, allowed ...string) error {
	for _, argument := range arguments {
		if strings.HasPrefix(argument, "-") && !contains(allowed, argument) {
			return fmt.Errorf("unknown flag %q", argument)
		}
	}
	return nil
}

func RequireAtMostArguments(commandName string, arguments []string, count int) error {
	if len(arguments) > count {
		return fmt.Errorf("%s accepts at most %d argument%s; run biot %s --help", commandName, count, plural(count), commandName)
	}
	return nil
}

func contains(values []string, wanted string) bool {
	for _, value := range values {
		if value == wanted {
			return true
		}
	}
	return false
}

func plural(count int) string {
	if count == 1 {
		return ""
	}
	return "s"
}
