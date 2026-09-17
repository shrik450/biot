package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/shrik450/biot/cli/internal/api"
	"github.com/shrik450/biot/cli/internal/command"
	"github.com/shrik450/biot/cli/internal/resolve"
)

const maxDisplayedOutputBytes = 64 << 10

func init() {
	rootCommand.Children = append(rootCommand.Children,
		&command.Command{
			Name:        "ssh",
			Synopsis:    "biot ssh NAME_OR_ID [--identity FILE] [-- COMMAND]",
			Description: "Open a shell in a Biot, or run one command and return its status.",
			Options: "  --identity FILE  Use FILE as the SSH private key.\n" +
				"  --               Pass the remaining arguments to SSH as the remote command.\n" +
				"  -h, --help       Show this help.",
			Run: runSSH,
		},
		&command.Command{
			Name:        "nodes",
			Synopsis:    "biot nodes",
			Description: "List registered nodes, capacity, connection state, and orphan reports.",
			Options:     "  -h, --help       Show this help.",
			Run:         runNodes,
		},
		&command.Command{
			Name:        "diagnose",
			Synopsis:    "biot diagnose NAME_OR_ID",
			Description: "Show the current failure diagnostic for a Biot.",
			Options:     "  -h, --help       Show this help.",
			Run:         runDiagnose,
		},
		&command.Command{
			Name:        "logs",
			Synopsis:    "biot logs NAME_OR_ID",
			Description: "Print a bounded tail of a Biot's runtime output.",
			Options:     "  -h, --help       Show this help.",
			Run:         runLogs,
		},
	)
}

func runSSH(commandContext command.Context, arguments []string) error {
	if len(arguments) == 0 {
		return errors.New("ssh expects a Biot name or ID; run biot ssh --help")
	}
	reference := arguments[0]
	identity := ""
	remoteCommand := []string(nil)
	for index := 1; index < len(arguments); index++ {
		switch arguments[index] {
		case "--identity":
			if index+1 >= len(arguments) || arguments[index+1] == "" {
				return errors.New("ssh requires a file after --identity; run biot ssh --help")
			}
			if identity != "" {
				return errors.New("ssh accepts --identity only once")
			}
			identity = arguments[index+1]
			index++
		case "--":
			remoteCommand = arguments[index+1:]
			index = len(arguments)
		default:
			return errors.New("ssh accepts only --identity FILE and -- before a remote command; run biot ssh --help")
		}
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
	deployment, err := client.GetDeployment(requestContext)
	if err != nil {
		return err
	}
	if deployment.SSH.Host == "" || deployment.SSH.Port < 1 || deployment.SSH.Port > 65_535 {
		return errors.New("the server returned unusable SSH connection details")
	}
	sshArguments := make([]string, 0, 5+len(remoteCommand))
	if identity != "" {
		sshArguments = append(sshArguments, "-i", identity)
	}
	sshArguments = append(sshArguments, "-p", fmt.Sprint(deployment.SSH.Port), biot.ID+"@"+deployment.SSH.Host)
	sshArguments = append(sshArguments, remoteCommand...)
	process := exec.Command("ssh", sshArguments...)
	process.Stdin = os.Stdin
	process.Stdout = commandContext.Stdout
	var sshError bytes.Buffer
	process.Stderr = io.MultiWriter(commandContext.Stderr, &sshError)
	if err := process.Run(); err != nil {
		var exitError *exec.ExitError
		if errors.As(err, &exitError) {
			status := exitError.ProcessState.ExitCode()
			if status < 0 {
				status = 1
				if waitStatus, ok := exitError.ProcessState.Sys().(syscall.WaitStatus); ok && waitStatus.Signaled() {
					status = 128 + int(waitStatus.Signal())
				}
			}
			if publicKeyAuthenticationFailure(sshError.String()) {
				fmt.Fprintln(commandContext.Stderr, "SSH authentication failed. Add a public key with biot ssh-key add FILE and make its private key available to ssh.")
			}
			return &exitStatusError{status: status}
		}
		return fmt.Errorf("start the SSH client: %w", err)
	}
	return nil
}

func runNodes(commandContext command.Context, arguments []string) error {
	if len(arguments) != 0 {
		return errors.New("nodes takes no arguments; run biot nodes --help")
	}
	client, err := loadClient()
	if err != nil {
		return err
	}
	requestContext, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	nodes, err := client.ListNodes(requestContext)
	if err != nil {
		return err
	}
	if len(nodes) == 0 {
		fmt.Fprintln(commandContext.Stdout, "No nodes.")
		return nil
	}
	fmt.Fprintln(commandContext.Stdout, "ID\tSTATUS\tPLATFORM\tCAPACITY\tCONNECTION\tORPHANS")
	for _, node := range nodes {
		platform := node.Platform
		if platform == "" {
			platform = "unknown"
		}
		var report nodeOrphanReport
		orphans := "orphan report unavailable"
		reportAvailable := false
		if err := json.Unmarshal(node.Orphans, &report); err == nil {
			switch report.Kind {
			case "never_reported":
				orphans = "never reported"
			case "reported":
				reportAvailable = true
				orphans = fmt.Sprintf("%d allocation(s)", len(report.Allocations))
				if report.ReportedAt != "" {
					orphans += ", reported " + report.ReportedAt
				}
			default:
				orphans = fmt.Sprintf("orphan report unavailable (unknown kind %q)", report.Kind)
			}
		}
		fmt.Fprintf(commandContext.Stdout, "%s\t%s\t%s\t%d/%d\t%s\t%s\n", node.ID, node.Status, platform, node.AssignedBiots, node.MaxBiots, node.Connection, orphans)
		if reportAvailable {
			for _, allocation := range report.Allocations {
				fmt.Fprintf(commandContext.Stdout, "  orphan: Biot %s, UID range %d-%d\n", allocation.BiotID, allocation.UIDRange.Start, allocation.UIDRange.Start+allocation.UIDRange.Count-1)
			}
		}
	}
	return nil
}

func runDiagnose(commandContext command.Context, arguments []string) error {
	if len(arguments) != 1 {
		return errors.New("diagnose expects a Biot name or ID; run biot diagnose --help")
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
	failure := diagnosticFailure(biot)
	if failure == nil || failure.DiagnosticRef == "" {
		return errors.New("That Biot has no current failure diagnostic.")
	}
	diagnostic, err := client.GetDiagnostic(requestContext, failure.DiagnosticRef)
	if err != nil {
		return err
	}
	printBoundedOutput(commandContext.Stdout, diagnostic.Content, diagnostic.Truncated, "diagnostic output")
	return nil
}

func runLogs(commandContext command.Context, arguments []string) error {
	if len(arguments) != 1 {
		return errors.New("logs expects a Biot name or ID; run biot logs --help")
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
	logs, err := client.GetRuntimeLogs(requestContext, biot.ID, maxDisplayedOutputBytes)
	if err != nil {
		return err
	}
	printBoundedOutput(commandContext.Stdout, logs.Content, logs.Truncated, "runtime logs")
	return nil
}

func diagnosticFailure(biot api.Biot) *api.Failure {
	if biot.Operation != nil && biot.Operation.TargetRevision == biot.Desired.Revision && biot.Operation.Outcome.Kind == "failed" {
		return biot.Operation.Outcome.Failure
	}
	if biot.Actual.Failure != nil && biot.Actual.Failure.TargetRevision == biot.Desired.Revision {
		return biot.Actual.Failure
	}
	return nil
}

func printBoundedOutput(output io.Writer, content string, truncated bool, label string) {
	if len(content) > maxDisplayedOutputBytes {
		content = truncateUTF8(content, maxDisplayedOutputBytes)
		truncated = true
	}
	if content == "" && !truncated {
		fmt.Fprintf(output, "No %s.\n", label)
		return
	}
	if content != "" {
		_, _ = io.WriteString(output, content)
		if !strings.HasSuffix(content, "\n") {
			_, _ = io.WriteString(output, "\n")
		}
	}
	if truncated {
		fmt.Fprintf(output, "[%s truncated; showing at most %d bytes.]\n", label, maxDisplayedOutputBytes)
	}
}

type nodeOrphanReport struct {
	Kind        string             `json:"kind"`
	ReportedAt  string             `json:"reported_at"`
	Allocations []orphanAllocation `json:"allocations"`
}

type orphanAllocation struct {
	BiotID   string `json:"biot_id"`
	UIDRange struct {
		Start int `json:"start"`
		Count int `json:"count"`
	} `json:"uid_range"`
}

func publicKeyAuthenticationFailure(message string) bool {
	message = strings.ToLower(message)
	return strings.Contains(message, "permission denied (publickey") ||
		strings.Contains(message, "no supported authentication methods available")
}

func truncateUTF8(value string, limit int) string {
	if len(value) <= limit {
		return value
	}
	end := limit
	for end > 0 && !utf8.ValidString(value[:end]) {
		end--
	}
	return value[:end]
}
