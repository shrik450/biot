package main

import (
	"context"
	"fmt"
	"strconv"
	"time"

	"github.com/shrik450/biot/cli/internal/api"
	"github.com/shrik450/biot/cli/internal/command"
	"github.com/shrik450/biot/cli/internal/resolve"
)

func init() {
	rootCommand.Children = append(rootCommand.Children,
		&command.Command{
			Name:        "publish",
			Synopsis:    "biot publish NAME_OR_ID PORT",
			Description: "Publish one port from a Biot and report its URL policy change.",
			Options:     "  -h, --help       Show this help.",
			Run:         runPublish,
		},
		&command.Command{
			Name:        "unpublish",
			Synopsis:    "biot unpublish NAME_OR_ID PORT",
			Description: "Stop publishing one port from a Biot.",
			Options:     "  -h, --help       Show this help.",
			Run:         runUnpublish,
		},
		&command.Command{
			Name:        "urls",
			Synopsis:    "biot urls NAME_OR_ID",
			Description: "Print the published URLs for a Biot, one pasteable URL per line.",
			Options:     "  -h, --help       Show this help.",
			Run:         runURLs,
		},
	)
}

func runPublish(commandContext command.Context, arguments []string) error {
	return runPublicationChange(commandContext, arguments, true)
}

func runUnpublish(commandContext command.Context, arguments []string) error {
	return runPublicationChange(commandContext, arguments, false)
}

func runPublicationChange(commandContext command.Context, arguments []string, publish bool) error {
	action := "unpublish"
	if publish {
		action = "publish"
	}
	if err := validateArguments(action, arguments, 2); err != nil {
		return err
	}
	port, err := parsePort(arguments[1], action)
	if err != nil {
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
	var result api.PolicyResult
	if publish {
		result, err = client.Publish(requestContext, biot.ID, port)
	} else {
		result, err = client.Unpublish(requestContext, biot.ID, port)
	}
	if err != nil {
		return err
	}
	if result.Result == "unchanged" {
		if publish {
			fmt.Fprintf(commandContext.Stdout, "Port %d is already published.\n", port)
		} else {
			fmt.Fprintf(commandContext.Stdout, "Port %d is not published.\n", port)
		}
		return nil
	}
	if publish {
		fmt.Fprintf(commandContext.Stdout, "Port %d published.\n", port)
	} else {
		fmt.Fprintf(commandContext.Stdout, "Port %d unpublished.\n", port)
	}
	return nil
}

func runURLs(commandContext command.Context, arguments []string) error {
	if err := validateArguments("urls", arguments, 1); err != nil {
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
	publications, err := client.ListPublications(requestContext, biot.ID)
	if err != nil {
		return err
	}
	if len(publications) == 0 {
		fmt.Fprintln(commandContext.Stdout, "No published URLs.")
		return nil
	}
	for _, publication := range publications {
		if publication.URL == "" {
			return fmt.Errorf("the server returned no URL for port %d", publication.Port)
		}
		fmt.Fprintln(commandContext.Stdout, publication.URL)
	}
	return nil
}

func parsePort(value string, action string) (int, error) {
	port, err := strconv.Atoi(value)
	if err != nil || port < 1 || port > 65_535 {
		return 0, fmt.Errorf("%s expects a port from 1 to 65535", action)
	}
	return port, nil
}
