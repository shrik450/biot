package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/shrik450/biot/cli/internal/api"
	"github.com/shrik450/biot/cli/internal/command"
	"github.com/shrik450/biot/cli/internal/id"
	"github.com/shrik450/biot/cli/internal/resolve"
)

type createOptions struct {
	repository       string
	name             string
	node             string
	layers           []string
	secretNames      []string
	fetchCredentials []string
	stdin            bool
}

func init() {
	rootCommand.Children = append(rootCommand.Children,
		&command.Command{
			Name:        "create",
			Synopsis:    "biot create --repo URL --name NAME [options]",
			Description: "Create a Biot and wait until it is ready.",
			Options: "  --repo URL              Required. HTTPS repository to check out.\n" +
				"  --name NAME             Required. Name for the new Biot.\n" +
				"  --node ID               Node ID (the server chooses one by default).\n" +
				"  --layer URL#REF         Nix layer source; repeatable.\n" +
				"  --secret NAME           Runtime secret name; repeatable.\n" +
				"  --fetch-credential URL  Source-fetch credential URL; repeatable.\n" +
				"  --stdin                 Read exactly one value from standard input; use with exactly one --secret or --fetch-credential.\n" +
				"  -h, --help              Show this help.",
			Run: runCreate,
		},
		&command.Command{
			Name:        "start",
			Synopsis:    "biot start NAME_OR_ID",
			Description: "Start a stopped Biot and report its lifecycle operation.",
			Options:     "  -h, --help       Show this help.",
			Run:         runStart,
		},
		&command.Command{
			Name:        "stop",
			Synopsis:    "biot stop NAME_OR_ID",
			Description: "Stop a running Biot and report its lifecycle operation.",
			Options:     "  -h, --help       Show this help.",
			Run:         runStop,
		},
		&command.Command{
			Name:        "restart",
			Synopsis:    "biot restart NAME_OR_ID",
			Description: "Stop a Biot, wait for it, then start it again.",
			Options:     "  -h, --help       Show this help.",
			Run:         runRestart,
		},
		&command.Command{
			Name:        "rebuild",
			Synopsis:    "biot rebuild NAME_OR_ID",
			Description: "Rebuild a Biot's current environment.",
			Options:     "  -h, --help       Show this help.",
			Run:         runRebuild,
		},
		&command.Command{
			Name:        "destroy",
			Synopsis:    "biot destroy NAME_OR_ID",
			Description: "Destroy a Biot permanently.",
			Options:     "  -h, --help       Show this help.",
			Run:         runDestroy,
		},
		&command.Command{
			Name:        "wait",
			Synopsis:    "biot wait NAME_OR_ID",
			Description: "Wait for the current lifecycle operation to finish.",
			Options:     "  -h, --help       Show this help.",
			Run:         runWait,
		},
	)
}

func runCreate(commandContext command.Context, arguments []string) error {
	options, err := parseCreateOptions(arguments)
	if err != nil {
		return err
	}
	phase := createPhasePrinter(commandContext.Stdout)
	phase("creating")
	biotID, err := id.New()
	if err != nil {
		return err
	}
	client, err := loadClient()
	if err != nil {
		return err
	}
	valuesRequired := len(options.secretNames) > 0 || len(options.fetchCredentials) > 0
	initialState := "running"
	if valuesRequired {
		initialState = "stopped"
	}
	layers := options.layers
	if layers == nil {
		layers = []string{}
	}
	environment := map[string]any{"base_nixpkgs": "nixpkgs", "layers": layers}
	body := map[string]any{
		"name":          options.name,
		"repository":    options.repository,
		"environment":   environment,
		"initial_state": initialState,
	}
	if options.node != "" {
		body["node_id"] = options.node
	}
	requestContext, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	defer cancel()
	result, err := client.CreateBiot(requestContext, biotID, body)
	if err != nil {
		return err
	}
	if !valuesRequired {
		phase("preparing")
		if result.OperationID != "" {
			if err := waitOperation(requestContext, client, result.OperationID, biotID, options.name); err != nil {
				return err
			}
		}
		phase("starting")
		if err := waitRunning(requestContext, client, biotID, options.name); err != nil {
			return err
		}
		fmt.Fprintln(commandContext.Stdout, "biot ready")
		return nil
	}

	phase("preparing")
	if _, err := waitAllocation(requestContext, client, biotID, options.name); err != nil {
		return credentialedCreateFailure(options.name, biotID, "biot start "+options.name, err)
	}
	if len(options.fetchCredentials) > 0 {
		phase("delivering fetch credentials")
	}
	for _, source := range options.fetchCredentials {
		value, err := readSensitiveValue(commandContext, options.stdin, "Source-fetch credential for "+source+": ")
		if err != nil {
			return credentialedCreateFailure(options.name, biotID, "biot fetch-credential set "+options.name+" "+source, fmt.Errorf("read source-fetch credential: %w", err))
		}
		err = client.DeliverFetchCredential(requestContext, biotID, source, value)
		clear(value)
		if err != nil {
			return credentialedCreateFailure(options.name, biotID, "biot fetch-credential set "+options.name+" "+source, fmt.Errorf("source-fetch credential delivery failed: %w", err))
		}
	}
	if len(options.fetchCredentials) > 0 {
		phase("preparing")
		if _, err := waitPrepared(requestContext, client, biotID, options.name); err != nil {
			return credentialedCreateFailure(options.name, biotID, "biot start "+options.name, err)
		}
	} else if result.OperationID != "" {
		if err := waitOperation(requestContext, client, result.OperationID, biotID, options.name); err != nil {
			return credentialedCreateFailure(options.name, biotID, "biot start "+options.name, err)
		}
	}
	view, err := client.GetBiot(requestContext, biotID)
	if err != nil {
		return credentialedCreateFailure(options.name, biotID, "biot start "+options.name, err)
	}
	if len(options.secretNames) > 0 {
		phase("delivering runtime secrets")
	}
	for _, name := range options.secretNames {
		value, err := readSensitiveValue(commandContext, options.stdin, "Runtime secret "+name+": ")
		if err != nil {
			return credentialedCreateFailure(options.name, biotID, "biot secret set "+options.name+" "+name, fmt.Errorf("read runtime secret: %w", err))
		}
		err = client.DeliverSecret(requestContext, biotID, name, value)
		clear(value)
		if err != nil {
			return credentialedCreateFailure(options.name, biotID, "biot secret set "+options.name+" "+name, fmt.Errorf("runtime secret delivery failed: %w", err))
		}
	}
	startResult, err := client.StartBiot(requestContext, biotID, view.Desired.Revision)
	if err != nil {
		return credentialedCreateFailure(options.name, biotID, "biot start "+options.name, err)
	}
	phase("starting")
	if startResult.OperationID != "" {
		if err := waitOperation(requestContext, client, startResult.OperationID, biotID, options.name); err != nil {
			return credentialedCreateFailure(options.name, biotID, "biot start "+options.name, err)
		}
	}
	if err := waitRunning(requestContext, client, biotID, options.name); err != nil {
		return credentialedCreateFailure(options.name, biotID, "biot start "+options.name, err)
	}
	fmt.Fprintln(commandContext.Stdout, "biot ready")
	return nil
}

func runStart(commandContext command.Context, arguments []string) error {
	return runLifecycle(commandContext, arguments, "start")
}

func runStop(commandContext command.Context, arguments []string) error {
	return runLifecycle(commandContext, arguments, "stop")
}

func runLifecycle(commandContext command.Context, arguments []string, action string) error {
	if err := validateArguments(action, arguments, 1); err != nil {
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
	var result api.LifecycleResult
	if action == "start" {
		result, err = client.StartBiot(requestContext, biot.ID, biot.Desired.Revision)
	} else {
		result, err = client.StopBiot(requestContext, biot.ID, biot.Desired.Revision)
	}
	if err != nil {
		return err
	}
	if result.OperationID == "" {
		fmt.Fprintf(commandContext.Stdout, "Biot is already %s.\n", lifecycleState(action))
		return nil
	}
	fmt.Fprintf(commandContext.Stdout, "operation %s accepted.\n", result.OperationID)
	return nil
}

func runRestart(commandContext command.Context, arguments []string) error {
	if err := validateArguments("restart", arguments, 1); err != nil {
		return err
	}
	client, err := loadClient()
	if err != nil {
		return err
	}
	requestContext, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	defer cancel()
	biot, err := resolve.Biot(requestContext, client, arguments[0])
	if err != nil {
		return err
	}
	stopResult, err := client.StopBiot(requestContext, biot.ID, biot.Desired.Revision)
	if err != nil {
		return err
	}
	if stopResult.OperationID != "" {
		if err := waitOperation(requestContext, client, stopResult.OperationID, biot.ID, arguments[0]); err != nil {
			return err
		}
	}
	view, err := client.GetBiot(requestContext, biot.ID)
	if err != nil {
		return err
	}
	startResult, err := client.StartBiot(requestContext, biot.ID, view.Desired.Revision)
	if err != nil {
		return err
	}
	if startResult.OperationID != "" {
		if err := waitOperation(requestContext, client, startResult.OperationID, biot.ID, arguments[0]); err != nil {
			return err
		}
	}
	if err := waitRunning(requestContext, client, biot.ID, arguments[0]); err != nil {
		return err
	}
	fmt.Fprintln(commandContext.Stdout, "biot ready")
	return nil
}

func runRebuild(commandContext command.Context, arguments []string) error {
	if err := validateArguments("rebuild", arguments, 1); err != nil {
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
	if biot.Environment == nil {
		return errors.New("the server did not return this Biot's current environment selection; update the server and try again")
	}
	result, err := client.RebuildBiot(requestContext, biot.ID, biot.Desired.Revision, biot.Environment)
	if err != nil {
		return err
	}
	if result.OperationID == "" {
		fmt.Fprintln(commandContext.Stdout, "The Biot environment is already current.")
		return nil
	}
	fmt.Fprintf(commandContext.Stdout, "operation %s accepted.\n", result.OperationID)
	return nil
}

func runDestroy(commandContext command.Context, arguments []string) error {
	if err := validateArguments("destroy", arguments, 1); err != nil {
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
	result, err := client.DestroyBiot(requestContext, biot.ID)
	if err != nil {
		return err
	}
	if result.OperationID == "" {
		fmt.Fprintln(commandContext.Stdout, "Biot is already destroyed.")
		return nil
	}
	fmt.Fprintf(commandContext.Stdout, "operation %s accepted.\n", result.OperationID)
	return nil
}

func runWait(commandContext command.Context, arguments []string) error {
	if err := validateArguments("wait", arguments, 1); err != nil {
		return err
	}
	client, err := loadClient()
	if err != nil {
		return err
	}
	requestContext, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	defer cancel()
	biot, err := resolve.Biot(requestContext, client, arguments[0])
	if err != nil {
		return err
	}
	if biot.Operation == nil {
		return errors.New("there is no operation in progress for that Biot")
	}
	if err := waitOperation(requestContext, client, biot.Operation.ID, biot.ID, arguments[0]); err != nil {
		return err
	}
	fmt.Fprintln(commandContext.Stdout, "operation succeeded.")
	return nil
}

func parseCreateOptions(arguments []string) (createOptions, error) {
	if err := rejectUnknown("create", arguments, "--repo", "--name", "--node", "--layer", "--secret", "--fetch-credential", "--stdin"); err != nil {
		return createOptions{}, err
	}
	options := createOptions{}
	for index := 0; index < len(arguments); index++ {
		argument := arguments[index]
		if argument == "--stdin" {
			options.stdin = true
			continue
		}
		if !strings.HasPrefix(argument, "--") || index+1 >= len(arguments) {
			return createOptions{}, fmt.Errorf("unknown or incomplete create option %q; run biot create --help", argument)
		}
		index++
		value := arguments[index]
		switch argument {
		case "--repo":
			options.repository = value
		case "--name":
			options.name = value
		case "--node":
			options.node = value
		case "--layer":
			options.layers = append(options.layers, value)
		case "--secret":
			options.secretNames = append(options.secretNames, value)
		case "--fetch-credential":
			options.fetchCredentials = append(options.fetchCredentials, value)
		default:
			return createOptions{}, fmt.Errorf("unknown create option %q; run biot create --help", argument)
		}
	}
	if options.repository == "" || options.name == "" {
		return createOptions{}, errors.New("create requires --repo and --name; run biot create --help")
	}
	credentialCount := len(options.secretNames) + len(options.fetchCredentials)
	if options.stdin && credentialCount != 1 {
		return createOptions{}, errors.New("--stdin requires exactly one --secret or --fetch-credential")
	}
	return options, nil
}

func credentialedCreateFailure(name string, biotID string, recovery string, cause error) error {
	return fmt.Errorf("Biot %q (%s) was created stopped but credentialed create failed: %w. After fixing it, run %s or biot destroy %s", name, biotID, cause, recovery, name)
}

func waitOperation(context context.Context, client *api.Client, operationID string, biotID string, reference string) error {
	return poll(context, reference, func() (bool, error) {
		operation, err := client.GetOperation(context, operationID)
		if err != nil {
			return false, err
		}
		switch operation.Outcome.Kind {
		case "pending", "working":
			if biotID != "" {
				biot, err := client.GetBiot(context, biotID)
				if err != nil {
					return false, err
				}
				if err := waitingForFailure(biot, reference); err != nil {
					return false, err
				}
			}
			return false, nil
		case "succeeded":
			return true, nil
		case "failed":
			return false, operationFailure(operation.Outcome.Failure, reference)
		case "superseded":
			return false, fmt.Errorf("the operation for Biot %q was superseded by a newer change; run biot show %s to inspect it", reference, reference)
		default:
			return false, fmt.Errorf("the server returned an unknown operation outcome %q", operation.Outcome.Kind)
		}
	})
}

func waitAllocation(context context.Context, client *api.Client, biotID string, reference string) (api.Biot, error) {
	var result api.Biot
	err := poll(context, reference, func() (bool, error) {
		biot, err := client.GetBiot(context, biotID)
		if err != nil {
			return false, err
		}
		if err := waitingForFailure(biot, reference); err != nil {
			return false, err
		}
		if err := currentFailure(biot, reference); err != nil {
			return false, err
		}
		result = biot
		return biot.Actual.Data == "uninitialized" || biot.Actual.Data == "present", nil
	})
	return result, err
}

func waitPrepared(context context.Context, client *api.Client, biotID string, reference string) (api.Biot, error) {
	var result api.Biot
	err := poll(context, reference, func() (bool, error) {
		biot, err := client.GetBiot(context, biotID)
		if err != nil {
			return false, err
		}
		if err := waitingForFailure(biot, reference); err != nil {
			return false, err
		}
		if err := currentFailure(biot, reference); err != nil {
			return false, err
		}
		result = biot
		return biot.Actual.InstalledEnvironment == biot.Desired.EnvironmentID, nil
	})
	return result, err
}

func waitRunning(context context.Context, client *api.Client, biotID string, reference string) error {
	return poll(context, reference, func() (bool, error) {
		biot, err := client.GetBiot(context, biotID)
		if err != nil {
			return false, err
		}
		if err := waitingForFailure(biot, reference); err != nil {
			return false, err
		}
		if err := currentFailure(biot, reference); err != nil {
			return false, err
		}
		if biot.Desired.State != "running" {
			return false, nil
		}
		return biot.Actual.Container.State == "running", nil
	})
}

func waitingForFailure(biot api.Biot, reference string) error {
	if biot.Actual.WaitingFor == nil {
		return nil
	}
	name := reference
	if name == "" {
		name = biot.Name
	}
	waiting := biot.Actual.WaitingFor
	if waiting.Kind == "fetch_credential" && waiting.Source != "" {
		return fmt.Errorf("Biot %q is waiting for source-fetch credential %q; run biot fetch-credential set %s %s", name, waiting.Source, name, waiting.Source)
	}
	if waiting.Kind == "" {
		return fmt.Errorf("Biot %q is waiting for an unavailable credential request; inspect it with biot show %s", name, name)
	}
	return fmt.Errorf("Biot %q is waiting for %s; inspect it with biot show %s", name, waiting.Kind, name)
}

func poll(context context.Context, reference string, check func() (bool, error)) error {
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()
	for {
		done, err := check()
		if err != nil {
			return err
		}
		if done {
			return nil
		}
		select {
		case <-context.Done():
			return fmt.Errorf("timed out waiting for Biot %q; run biot show %s to inspect it", reference, reference)
		case <-ticker.C:
		}
	}
}

func currentFailure(biot api.Biot, reference string) error {
	if biot.Operation != nil && biot.Operation.TargetRevision == biot.Desired.Revision && biot.Operation.Outcome.Kind == "failed" {
		return operationFailure(biot.Operation.Outcome.Failure, reference)
	}
	if biot.Actual.Failure != nil && biot.Actual.Failure.TargetRevision == biot.Desired.Revision {
		return operationFailure(biot.Actual.Failure, reference)
	}
	return nil
}

func lifecycleState(action string) string {
	if action == "start" {
		return "running"
	}
	return "stopped"
}

func operationFailure(failure *api.Failure, reference string) error {
	if failure == nil {
		message := "the Biot operation failed; run biot show to inspect it"
		if reference != "" {
			message += fmt.Sprintf("; run biot diagnose %s for more", reference)
		}
		return errors.New(message)
	}
	message := fmt.Sprintf("%s / %s: %s", failure.Stage, failure.Code, failure.Message)
	if reference != "" {
		message += fmt.Sprintf("; run biot diagnose %s for more", reference)
	}
	return errors.New(message)
}

func createPhasePrinter(output io.Writer) func(string) {
	last := ""
	return func(phase string) {
		if phase == last {
			return
		}
		last = phase
		fmt.Fprintf(output, "biot %s\n", phase)
	}
}
