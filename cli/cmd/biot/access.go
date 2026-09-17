package main

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/shrik450/biot/cli/internal/api"
	"github.com/shrik450/biot/cli/internal/command"
	"github.com/shrik450/biot/cli/internal/resolve"
)

type shareOptions struct {
	biot  string
	email string
	port  int
	shell bool
}

func init() {
	rootCommand.Children = append(rootCommand.Children,
		&command.Command{
			Name:        "share",
			Synopsis:    "biot share NAME_OR_ID --to EMAIL (--port PORT | --shell)",
			Description: "Give one person shell access or access to one published port.",
			Options: "  --to EMAIL       Required. Person to grant access to.\n" +
				"  --port PORT      Grant access to one published port.\n" +
				"  --shell          Grant shell access.\n" +
				"  -h, --help       Show this help.",
			Run: runShare,
		},
		&command.Command{
			Name:        "unshare",
			Synopsis:    "biot unshare NAME_OR_ID --to EMAIL (--port PORT | --shell)",
			Description: "Remove one person's shell access or publication access.",
			Options: "  --to EMAIL       Required. Person whose access should be removed.\n" +
				"  --port PORT      Remove access to one published port.\n" +
				"  --shell          Remove shell access.\n" +
				"  -h, --help       Show this help.",
			Run: runUnshare,
		},
		&command.Command{
			Name:        "grants",
			Synopsis:    "biot grants NAME_OR_ID",
			Description: "Show the owner and explicit access grants for a Biot.",
			Options:     "  -h, --help       Show this help.",
			Run:         runGrants,
		},
	)
}

func runShare(commandContext command.Context, arguments []string) error {
	return runShareChange(commandContext, arguments, true)
}

func runUnshare(commandContext command.Context, arguments []string) error {
	return runShareChange(commandContext, arguments, false)
}

func runShareChange(commandContext command.Context, arguments []string, grant bool) error {
	action := "unshare"
	if grant {
		action = "share"
	}
	options, err := parseShareOptions(action, arguments)
	if err != nil {
		return err
	}
	client, err := loadClient()
	if err != nil {
		return err
	}
	requestContext, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	biot, err := resolve.Biot(requestContext, client, options.biot)
	if err != nil {
		return err
	}
	principal, err := client.ResolvePrincipal(requestContext, options.email)
	if err != nil {
		var apiError *api.Error
		if errors.As(err, &apiError) && apiError.Tag == "not_found" {
			return fmt.Errorf("That principal could not be found for %q.", options.email)
		}
		return err
	}
	if principal.ID == "" {
		return fmt.Errorf("the server returned no principal ID for %q", options.email)
	}
	var result api.PolicyResult
	if options.shell {
		if grant {
			result, err = client.GrantShell(requestContext, biot.ID, principal.ID)
		} else {
			result, err = client.RevokeShell(requestContext, biot.ID, principal.ID)
		}
	} else if grant {
		result, err = client.GrantView(requestContext, biot.ID, options.port, principal.ID)
	} else {
		result, err = client.RevokeView(requestContext, biot.ID, options.port, principal.ID)
	}
	if err != nil {
		return err
	}
	return printShareResult(commandContext, result, options, grant)
}

func printShareResult(commandContext command.Context, result api.PolicyResult, options shareOptions, grant bool) error {
	kind := "view access"
	if options.shell {
		kind = "shell access"
	}
	if result.Result != "applied" && result.Result != "unchanged" {
		return errors.New("the server returned an unexpected access policy result")
	}
	if result.Result == "unchanged" {
		if grant {
			fmt.Fprintf(commandContext.Stdout, "%s for %s is already set.\n", shareDescription(kind, options), options.email)
		} else {
			fmt.Fprintf(commandContext.Stdout, "%s for %s was not set.\n", shareDescription(kind, options), options.email)
		}
		return nil
	}
	verb := "granted"
	if !grant {
		verb = "removed"
	}
	fmt.Fprintf(commandContext.Stdout, "%s %s for %s.\n", shareDescription(kind, options), verb, options.email)
	return nil
}

func shareDescription(kind string, options shareOptions) string {
	if options.shell {
		return "Shell access"
	}
	return fmt.Sprintf("%s on port %d", strings.ToUpper(kind[:1])+kind[1:], options.port)
}

func parseShareOptions(action string, arguments []string) (shareOptions, error) {
	if err := rejectUnknown(action, arguments, "--to", "--port", "--shell"); err != nil {
		return shareOptions{}, err
	}
	if len(arguments) == 0 {
		return shareOptions{}, fmt.Errorf("%s expects a Biot name or ID and sharing options; run biot %s --help", action, action)
	}
	options := shareOptions{biot: arguments[0]}
	for index := 1; index < len(arguments); index++ {
		switch arguments[index] {
		case "--to":
			if index+1 >= len(arguments) || arguments[index+1] == "" {
				return shareOptions{}, fmt.Errorf("%s requires an email after --to", action)
			}
			if options.email != "" {
				return shareOptions{}, fmt.Errorf("%s accepts --to only once", action)
			}
			options.email = arguments[index+1]
			index++
		case "--port":
			if index+1 >= len(arguments) {
				return shareOptions{}, fmt.Errorf("%s requires a port after --port", action)
			}
			if options.port != 0 {
				return shareOptions{}, fmt.Errorf("%s accepts --port only once", action)
			}
			port, err := parsePort(arguments[index+1], action)
			if err != nil {
				return shareOptions{}, err
			}
			options.port = port
			index++
		case "--shell":
			if options.shell {
				return shareOptions{}, fmt.Errorf("%s accepts --shell only once", action)
			}
			options.shell = true
		default:
			return shareOptions{}, fmt.Errorf("unknown %s option %q; run biot %s --help", action, arguments[index], action)
		}
	}
	if options.email == "" {
		return shareOptions{}, fmt.Errorf("%s requires --to EMAIL", action)
	}
	if options.shell && options.port != 0 {
		return shareOptions{}, fmt.Errorf("%s accepts either --shell or --port, not both", action)
	}
	if !options.shell && options.port == 0 {
		return shareOptions{}, fmt.Errorf("%s requires either --shell or --port PORT", action)
	}
	return options, nil
}

func runGrants(commandContext command.Context, arguments []string) error {
	if err := validateArguments("grants", arguments, 1); err != nil {
		return err
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
	grants, err := client.GetGrants(requestContext, biot.ID)
	if err != nil {
		return err
	}
	fmt.Fprintf(commandContext.Stdout, "owner: %s\n", grantPrincipal(grants.Owner))
	if len(grants.Grants) == 0 {
		fmt.Fprintln(commandContext.Stdout, "No explicit grants.")
		return nil
	}
	for _, grant := range grants.Grants {
		if grant.Kind == "shell" {
			fmt.Fprintf(commandContext.Stdout, "shell: %s\n", grantPrincipal(grant.Principal))
			continue
		}
		if grant.Kind == "view" {
			fmt.Fprintf(commandContext.Stdout, "view port %d: %s\n", grant.Port, grantPrincipal(grant.Principal))
			continue
		}
		return fmt.Errorf("the server returned an unknown grant kind %q", grant.Kind)
	}
	return nil
}

func grantPrincipal(principal api.Principal) string {
	if principal.Email != "" {
		return fmt.Sprintf("%s (principal ID %s)", principal.Email, principal.ID)
	}
	if principal.Name != "" {
		return fmt.Sprintf("%s (email unavailable; principal ID %s)", principal.Name, principal.ID)
	}
	if principal.ID != "" {
		return fmt.Sprintf("email unavailable; principal ID %s", principal.ID)
	}
	return "email unavailable; principal ID unavailable"
}
