package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/shrik450/biot/cli/internal/command"
	"github.com/shrik450/biot/cli/internal/input"
	"github.com/shrik450/biot/cli/internal/resolve"
)

func init() {
	rootCommand.Children = append(rootCommand.Children,
		&command.Command{
			Name:        "secret",
			Synopsis:    "biot secret <set|rm|list> ...",
			Description: "Deliver, remove, or list runtime secrets without displaying their values.",
			Options:     "  -h, --help       Show this help.",
			Children: []*command.Command{
				{
					Name:        "set",
					Synopsis:    "biot secret set NAME_OR_ID SECRET_NAME [--stdin]",
					Description: "Read one hidden runtime secret value and deliver it to a Biot.",
					Options: "  --stdin         Read exactly one value from standard input.\n" +
						"  -h, --help       Show this help.",
					Run: runSecretSet,
				},
				{
					Name:        "rm",
					Synopsis:    "biot secret rm NAME_OR_ID SECRET_NAME",
					Description: "Remove one runtime secret from a Biot.",
					Options:     "  -h, --help       Show this help.",
					Run:         runSecretRemove,
				},
				{
					Name:        "list",
					Synopsis:    "biot secret list NAME_OR_ID",
					Description: "List runtime secret names without showing their values.",
					Options:     "  -h, --help       Show this help.",
					Run:         runSecretList,
				},
			},
		},
		&command.Command{
			Name:        "fetch-credential",
			Synopsis:    "biot fetch-credential <set|rm> ...",
			Description: "Deliver or remove a source-fetch credential without displaying its value.",
			Options:     "  -h, --help       Show this help.",
			Children: []*command.Command{
				{
					Name:        "set",
					Synopsis:    "biot fetch-credential set NAME_OR_ID SOURCE_URL [--stdin]",
					Description: "Read one hidden source-fetch credential and deliver it to a Biot.",
					Options: "  --stdin         Read exactly one value from standard input.\n" +
						"  -h, --help       Show this help.",
					Run: runFetchCredentialSet,
				},
				{
					Name:        "rm",
					Synopsis:    "biot fetch-credential rm NAME_OR_ID SOURCE_URL",
					Description: "Remove one source-fetch credential from a Biot.",
					Options:     "  -h, --help       Show this help.",
					Run:         runFetchCredentialRemove,
				},
			},
		},
	)
}

func runSecretSet(commandContext command.Context, arguments []string) error {
	reference, name, stdin, err := parseValueCommand("secret set", arguments)
	if err != nil {
		return err
	}
	client, err := loadClient()
	if err != nil {
		return err
	}
	requestContext, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	biot, err := resolve.Biot(requestContext, client, reference)
	if err != nil {
		return err
	}
	value, err := readSensitiveValue(commandContext, stdin, "Runtime secret value: ")
	if err != nil {
		return err
	}
	defer clear(value)
	if err := client.DeliverSecret(requestContext, biot.ID, name, value); err != nil {
		return fmt.Errorf("runtime secret delivery failed: %w", err)
	}
	fmt.Fprintf(commandContext.Stdout, "Runtime secret %s delivered.\n", name)
	return nil
}

func runSecretRemove(commandContext command.Context, arguments []string) error {
	if len(arguments) != 2 {
		return errors.New("secret rm expects a Biot name or ID and a secret name; run biot secret rm --help")
	}
	client, err := loadClient()
	if err != nil {
		return err
	}
	requestContext, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	biot, err := resolve.Biot(requestContext, client, arguments[0])
	if err != nil {
		return err
	}
	if err := client.RemoveSecret(requestContext, biot.ID, arguments[1]); err != nil {
		return fmt.Errorf("runtime secret removal failed: %w", err)
	}
	fmt.Fprintf(commandContext.Stdout, "Runtime secret %s removed.\n", arguments[1])
	return nil
}

func runSecretList(commandContext command.Context, arguments []string) error {
	if len(arguments) != 1 {
		return errors.New("secret list expects a Biot name or ID; run biot secret list --help")
	}
	client, err := loadClient()
	if err != nil {
		return err
	}
	requestContext, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	biot, err := resolve.Biot(requestContext, client, arguments[0])
	if err != nil {
		return err
	}
	secrets, err := client.ListSecrets(requestContext, biot.ID)
	if err != nil {
		return err
	}
	if len(secrets) == 0 {
		fmt.Fprintln(commandContext.Stdout, "No runtime secrets.")
		return nil
	}
	for _, secret := range secrets {
		fmt.Fprintln(commandContext.Stdout, secret.Name)
	}
	return nil
}

func runFetchCredentialSet(commandContext command.Context, arguments []string) error {
	reference, source, stdin, err := parseValueCommand("fetch-credential set", arguments)
	if err != nil {
		return err
	}
	client, err := loadClient()
	if err != nil {
		return err
	}
	requestContext, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	biot, err := resolve.Biot(requestContext, client, reference)
	if err != nil {
		return err
	}
	value, err := readSensitiveValue(commandContext, stdin, "Source-fetch credential value: ")
	if err != nil {
		return err
	}
	defer clear(value)
	if err := client.DeliverFetchCredential(requestContext, biot.ID, source, value); err != nil {
		return fmt.Errorf("source-fetch credential delivery failed: %w", err)
	}
	fmt.Fprintf(commandContext.Stdout, "Source-fetch credential for %s delivered.\n", source)
	return nil
}

func runFetchCredentialRemove(commandContext command.Context, arguments []string) error {
	if len(arguments) != 2 {
		return errors.New("fetch-credential rm expects a Biot name or ID and a source URL; run biot fetch-credential rm --help")
	}
	client, err := loadClient()
	if err != nil {
		return err
	}
	requestContext, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	biot, err := resolve.Biot(requestContext, client, arguments[0])
	if err != nil {
		return err
	}
	if err := client.RemoveFetchCredential(requestContext, biot.ID, arguments[1]); err != nil {
		return fmt.Errorf("source-fetch credential removal failed: %w", err)
	}
	fmt.Fprintf(commandContext.Stdout, "Source-fetch credential for %s removed.\n", arguments[1])
	return nil
}

func parseValueCommand(action string, arguments []string) (string, string, bool, error) {
	positionals := make([]string, 0, 2)
	stdin := false
	for _, argument := range arguments {
		if argument == "--stdin" {
			if stdin {
				return "", "", false, fmt.Errorf("%s accepts --stdin only once", action)
			}
			stdin = true
			continue
		}
		if strings.HasPrefix(argument, "-") {
			return "", "", false, fmt.Errorf("unknown %s option %q; run biot %s --help", action, argument, action)
		}
		positionals = append(positionals, argument)
	}
	if len(positionals) != 2 {
		return "", "", false, fmt.Errorf("%s expects a Biot name or ID and a value name; run biot %s --help", action, action)
	}
	return positionals[0], positionals[1], stdin, nil
}

func readSensitiveValue(commandContext command.Context, stdin bool, prompt string) ([]byte, error) {
	if stdin {
		return input.StdinSecret(os.Stdin)
	}
	terminal, closeTerminal := openTerminal()
	defer closeTerminal()
	if terminal == os.Stdin && !input.IsTerminal(terminal) {
		return nil, errors.New("standard input is not a terminal; use --stdin to provide the value")
	}
	return input.Secret(prompt, terminal, commandContext.Stderr)
}
