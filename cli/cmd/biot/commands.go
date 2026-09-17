package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"time"

	"github.com/shrik450/biot/cli/internal/api"
	"github.com/shrik450/biot/cli/internal/command"
	"github.com/shrik450/biot/cli/internal/config"
	"github.com/shrik450/biot/cli/internal/input"
	"github.com/shrik450/biot/cli/internal/resolve"
)

const secretExposureWarning = "may contain supplied secrets. This is a historical marker; it does not show whether a secret is present now."

func init() {
	rootCommand.Children = append(rootCommand.Children, []*command.Command{
		{
			Name:        "help",
			Synopsis:    "biot help",
			Description: "Show the Biot command list and the first steps for a new user.",
			Options:     "  -h, --help       Show this help.",
			Run: func(commandContext command.Context, arguments []string) error {
				if err := rejectUnknown("help", arguments); err != nil {
					return err
				}
				if err := command.RequireArguments("help", arguments, 0); err != nil {
					return err
				}
				return rootCommand.Help(commandContext, nil)
			},
		},
		{
			Name:        "login",
			Synopsis:    "biot login [SERVER_URL]",
			Description: "Open the account page, save a bearer token, and verify it. SERVER_URL is the HTTP or HTTPS address of your Biot server, such as https://biot.example.com.",
			Options:     "  -h, --help       Show this help.",
			Run:         runLogin,
		},
		{
			Name:        "logout",
			Synopsis:    "biot logout",
			Description: "Remove the saved server URL and bearer token from this machine.",
			Options:     "  -h, --help       Show this help.",
			Run:         runLogout,
		},
		{
			Name:        "list",
			Synopsis:    "biot list",
			Description: "List the Biots you can read.",
			Options:     "  -h, --help       Show this help.",
			Run:         runList,
		},
		{
			Name:        "show",
			Synopsis:    "biot show NAME_OR_ID",
			Description: "Show one Biot by name or canonical ID.",
			Options:     "  -h, --help       Show this help.",
			Run:         runShow,
		},
	}...)
}

func runLogin(commandContext command.Context, arguments []string) error {
	if err := rejectUnknown("login", arguments); err != nil {
		return err
	}
	if err := command.RequireAtMostArguments("login", arguments, 1); err != nil {
		return err
	}
	terminal, closeTerminal := openTerminal()
	defer closeTerminal()
	serverURL := ""
	var standardInput *bufio.Reader
	if !input.IsTerminal(os.Stdin) {
		standardInput = bufio.NewReader(os.Stdin)
	}
	if len(arguments) == 1 {
		serverURL = arguments[0]
	} else {
		var err error
		reader := io.Reader(terminal)
		if standardInput != nil {
			reader = standardInput
		}
		serverURL, err = input.Line("Server URL: ", reader, commandContext.Stderr)
		if err != nil {
			return fmt.Errorf("read server URL: %w", err)
		}
	}
	client, err := api.New(serverURL, "", http.DefaultTransport)
	if err != nil {
		return err
	}
	accountURL := strings.TrimRight(client.ServerURL(), "/") + "/account"
	fmt.Fprintf(commandContext.Stdout, "Open this URL to create or copy a bearer token:\n%s\n", accountURL)
	tryOpenBrowser(accountURL, commandContext.Stderr)

	var token []byte
	if standardInput == nil {
		token, err = input.Secret("Bearer token: ", terminal, commandContext.Stderr)
	} else {
		token, err = input.StdinToken(standardInput)
	}
	if err != nil {
		return err
	}
	defer clear(token)
	client, err = api.New(serverURL, string(token), http.DefaultTransport)
	if err != nil {
		return err
	}
	requestContext, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	principal, err := client.Me(requestContext)
	if err != nil {
		if api.IsUnauthenticated(err) {
			return errors.New("The token was not accepted. Check the token and run biot login again.")
		}
		return err
	}
	if err := config.Save(config.Config{ServerURL: client.ServerURL(), Token: string(token)}); err != nil {
		return err
	}
	fmt.Fprintf(commandContext.Stdout, "Logged in as %s.\n", principalLabel(principal))
	return nil
}

func principalLabel(principal api.Principal) string {
	if principal.Email != "" {
		return principal.Email
	}
	if principal.Name != "" {
		return principal.Name
	}
	return principal.ID
}

func runLogout(commandContext command.Context, arguments []string) error {
	if err := validateArguments("logout", arguments, 0); err != nil {
		return err
	}
	saved, err := config.Exists()
	if err != nil {
		return err
	}
	if err := config.Remove(); err != nil {
		return err
	}
	if !saved {
		fmt.Fprintln(commandContext.Stdout, "There was no saved session.")
		return nil
	}
	fmt.Fprintln(commandContext.Stdout, "Logged out.")
	return nil
}

func runList(commandContext command.Context, arguments []string) error {
	if err := validateArguments("list", arguments, 0); err != nil {
		return err
	}
	client, err := loadClient()
	if err != nil {
		return err
	}
	requestContext, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	biots, err := client.ListBiots(requestContext)
	if err != nil {
		return err
	}
	if len(biots) == 0 {
		fmt.Fprintln(commandContext.Stdout, "No Biots.")
		return nil
	}
	fmt.Fprintln(commandContext.Stdout, "NAME\tID\tDESIRED\tACTUAL\tNODE\tWAITING FOR\tSECRETS")
	for _, biot := range biots {
		secretMarker := ""
		if biot.DirectSecretExposurePossible {
			secretMarker = secretExposureWarning
		}
		fmt.Fprintf(commandContext.Stdout, "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", biot.Name, biot.ID, biot.Desired.State, actualContainerLabel(biot), biot.Node, waitingForLabel(biot.Actual.WaitingFor), secretMarker)
	}
	return nil
}

func runShow(commandContext command.Context, arguments []string) error {
	if err := validateArguments("show", arguments, 1); err != nil {
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
	printBiot(commandContext.Stdout, biot)
	return nil
}

func loadClient() (*api.Client, error) {
	value, err := config.Load()
	if err != nil {
		return nil, err
	}
	return api.New(value.ServerURL, value.Token, http.DefaultTransport)
}

func printBiot(output io.Writer, biot api.Biot) {
	fmt.Fprintf(output, "name: %s\n", biot.Name)
	fmt.Fprintf(output, "id: %s\n", biot.ID)
	fmt.Fprintf(output, "role: %s\n", roleLabel(biot.Role))
	fmt.Fprintf(output, "desired: %s (revision %d)\n", biot.Desired.State, biot.Desired.Revision)
	fmt.Fprintf(output, "node: %s\n", biot.Node)
	if biot.Operation == nil {
		fmt.Fprintln(output, "operation: none")
	} else {
		fmt.Fprintf(output, "operation: %s %s\n", operationKindLabel(biot.Operation.Kind), biot.Operation.Outcome.Kind)
		if biot.Operation.Outcome.Failure != nil {
			fmt.Fprintf(output, "failure: %s / %s: %s\n", biot.Operation.Outcome.Failure.Stage, biot.Operation.Outcome.Failure.Code, biot.Operation.Outcome.Failure.Message)
		}
	}
	if biot.Actual.Kind == "never_reported" {
		fmt.Fprintln(output, "actual: never reported")
	} else {
		fmt.Fprintf(output, "actual: %s (%s)\n", biot.Actual.Data, biot.Actual.Freshness)
	}
	fmt.Fprintf(output, "container: %s\n", actualContainerLabel(biot))
	if waiting := waitingForLabel(biot.Actual.WaitingFor); waiting != "" {
		fmt.Fprintf(output, "waiting for: %s\n", waiting)
	}
	if biot.DirectSecretExposurePossible {
		fmt.Fprintf(output, "warning: %s\n", secretExposureWarning)
	}
	if len(biot.Publications) > 0 {
		fmt.Fprintln(output, "publications:")
		for _, publication := range biot.Publications {
			fmt.Fprintf(output, "  %d %s\n", publication.Port, publication.URL)
		}
	}
}

func actualContainerLabel(biot api.Biot) string {
	if biot.Actual.Kind == "never_reported" {
		return "never reported"
	}
	container := biot.Actual.Container
	switch container.Kind {
	case "present":
		if container.State == "exited" && container.Status != nil {
			return fmt.Sprintf("exited (status %d)", *container.Status)
		}
		if container.State != "" {
			return container.State
		}
		return "present"
	case "absent", "unknown":
		return container.Kind
	default:
		return "unavailable"
	}
}

func waitingForLabel(waiting *api.WaitingFor) string {
	if waiting == nil {
		return ""
	}
	if waiting.Kind == "fetch_credential" {
		return "fetch credential " + waiting.Source
	}
	if waiting.Kind == "" {
		return "unavailable"
	}
	return waiting.Kind
}

func roleLabel(role api.Role) string {
	if role.Kind == "owner" {
		return "owner"
	}
	values := make([]string, 0, 1+len(role.ViewPorts))
	if role.Shell {
		values = append(values, "shell")
	}
	if len(role.ViewPorts) > 0 {
		ports := make([]string, len(role.ViewPorts))
		for index, port := range role.ViewPorts {
			ports[index] = fmt.Sprint(port)
		}
		values = append(values, "view "+strings.Join(ports, ", "))
	}
	if len(values) == 0 {
		return "collaborator · view"
	}
	return "collaborator · " + strings.Join(values, ", ")
}

func operationKindLabel(kind string) string {
	if kind == "update_environment" {
		return "update environment"
	}
	return kind
}

func openTerminal() (*os.File, func()) {
	if terminal, err := os.OpenFile("/dev/tty", os.O_RDWR, 0); err == nil {
		return terminal, func() { terminal.Close() }
	}
	return os.Stdin, func() {}
}

func tryOpenBrowser(target string, output io.Writer) {
	program, arguments := browserCommand(target)
	process := exec.Command(program, arguments...)
	if err := process.Start(); err != nil {
		fmt.Fprintf(output, "Could not open a browser automatically; open the URL above manually.\n")
		return
	}
	_ = process.Process.Release()
}

func browserCommand(target string) (string, []string) {
	switch runtime.GOOS {
	case "darwin":
		return "open", []string{target}
	case "windows":
		return "rundll32", []string{"url.dll,FileProtocolHandler", target}
	default:
		return "xdg-open", []string{target}
	}
}
