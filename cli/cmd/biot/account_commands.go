package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/shrik450/biot/cli/internal/command"
)

func init() {
	rootCommand.Children = append(rootCommand.Children,
		&command.Command{
			Name:        "ssh-key",
			Synopsis:    "biot ssh-key <add|list|rm> ...",
			Description: "Register and remove public SSH keys for shell access.",
			Options:     "  -h, --help       Show this help.",
			Children: []*command.Command{
				{
					Name:        "add",
					Synopsis:    "biot ssh-key add FILE",
					Description: "Register the public key in FILE; its filename becomes the key label.",
					Options:     "  -h, --help       Show this help.",
					Run:         runSSHKeyAdd,
				},
				{
					Name:        "list",
					Synopsis:    "biot ssh-key list",
					Description: "List registered public SSH keys.",
					Options:     "  -h, --help       Show this help.",
					Run:         runSSHKeyList,
				},
				{
					Name:        "rm",
					Synopsis:    "biot ssh-key rm ID",
					Description: "Remove a registered public SSH key by ID.",
					Options:     "  -h, --help       Show this help.",
					Run:         runSSHKeyRemove,
				},
			},
		},
		&command.Command{
			Name:        "token",
			Synopsis:    "biot token <create|list|revoke> ...",
			Description: "Open the account page or manage this account's bearer credentials.",
			Options:     "  -h, --help       Show this help.",
			Children: []*command.Command{
				{
					Name:        "create",
					Synopsis:    "biot token create",
					Description: "Print the account page URL and open it to create a bearer token.",
					Options:     "  -h, --help       Show this help.",
					Run:         runTokenCreate,
				},
				{
					Name:        "list",
					Synopsis:    "biot token list",
					Description: "List bearer credentials without displaying their token values.",
					Options:     "  -h, --help       Show this help.",
					Run:         runTokenList,
				},
				{
					Name:        "revoke",
					Synopsis:    "biot token revoke ID",
					Description: "Revoke one bearer credential by ID.",
					Options:     "  -h, --help       Show this help.",
					Run:         runTokenRevoke,
				},
			},
		},
	)
}

func runSSHKeyAdd(commandContext command.Context, arguments []string) error {
	if err := validateArguments("ssh-key add", arguments, 1); err != nil {
		return err
	}
	contents, err := os.ReadFile(arguments[0])
	if err != nil {
		return fmt.Errorf("read public SSH key %q: %w", arguments[0], err)
	}
	publicKey := strings.TrimSpace(string(contents))
	if publicKey == "" {
		return errors.New("the public SSH key file is empty")
	}
	label := filepath.Base(arguments[0])
	if label == "." || label == string(filepath.Separator) || label == "" {
		return errors.New("the public SSH key file has no usable name for its label")
	}
	client, err := loadClient()
	if err != nil {
		return err
	}
	requestContext, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	key, err := client.AddSSHKey(requestContext, publicKey, label)
	if err != nil {
		return fmt.Errorf("add public SSH key: %w", err)
	}
	if key.ID == "" || key.Fingerprint == "" {
		return errors.New("the server returned an incomplete SSH key")
	}
	fmt.Fprintf(commandContext.Stdout, "SSH key %s added (%s).\n", key.Label, key.Fingerprint)
	return nil
}

func runSSHKeyList(commandContext command.Context, arguments []string) error {
	if err := validateArguments("ssh-key list", arguments, 0); err != nil {
		return err
	}
	client, err := loadClient()
	if err != nil {
		return err
	}
	requestContext, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	keys, err := client.ListSSHKeys(requestContext)
	if err != nil {
		return err
	}
	if len(keys) == 0 {
		fmt.Fprintln(commandContext.Stdout, "No SSH keys.")
		return nil
	}
	fmt.Fprintln(commandContext.Stdout, "LABEL\tID\tFINGERPRINT\tPUBLIC KEY")
	for _, key := range keys {
		fmt.Fprintf(commandContext.Stdout, "%s\t%s\t%s\t%s\n", key.Label, key.ID, key.Fingerprint, key.PublicKey)
	}
	return nil
}

func runSSHKeyRemove(commandContext command.Context, arguments []string) error {
	if err := validateArguments("ssh-key rm", arguments, 1); err != nil {
		return err
	}
	client, err := loadClient()
	if err != nil {
		return err
	}
	requestContext, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := client.RemoveSSHKey(requestContext, arguments[0]); err != nil {
		return fmt.Errorf("remove public SSH key: %w", err)
	}
	fmt.Fprintf(commandContext.Stdout, "SSH key %s removed.\n", arguments[0])
	return nil
}

func runTokenCreate(commandContext command.Context, arguments []string) error {
	if err := validateArguments("token create", arguments, 0); err != nil {
		return err
	}
	client, err := loadClient()
	if err != nil {
		return err
	}
	accountURL := strings.TrimRight(client.ServerURL(), "/") + "/account"
	fmt.Fprintf(commandContext.Stdout, "Open this URL to create or copy a bearer token:\n%s\n", accountURL)
	tryOpenBrowser(accountURL, commandContext.Stderr)
	return nil
}

func runTokenList(commandContext command.Context, arguments []string) error {
	if err := validateArguments("token list", arguments, 0); err != nil {
		return err
	}
	client, err := loadClient()
	if err != nil {
		return err
	}
	requestContext, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	credentials, err := client.ListCredentials(requestContext)
	if err != nil {
		return err
	}
	if len(credentials) == 0 {
		fmt.Fprintln(commandContext.Stdout, "No bearer credentials.")
		return nil
	}
	fmt.Fprintln(commandContext.Stdout, "LABEL\tID\tEXPIRES\tLAST USED")
	for _, credential := range credentials {
		lastUsed := credential.LastUsedAt
		if lastUsed == "" {
			lastUsed = "never"
		}
		fmt.Fprintf(commandContext.Stdout, "%s\t%s\t%s\t%s\n", credential.Label, credential.ID, credential.ExpiresAt, lastUsed)
	}
	return nil
}

func runTokenRevoke(commandContext command.Context, arguments []string) error {
	if err := validateArguments("token revoke", arguments, 1); err != nil {
		return err
	}
	client, err := loadClient()
	if err != nil {
		return err
	}
	requestContext, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := client.RevokeCredential(requestContext, arguments[0]); err != nil {
		return fmt.Errorf("revoke bearer credential: %w", err)
	}
	fmt.Fprintf(commandContext.Stdout, "Bearer credential %s revoked.\n", arguments[0])
	return nil
}
