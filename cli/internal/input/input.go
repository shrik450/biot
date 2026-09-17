package input

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"

	"github.com/shrik450/biot/cli/internal/api"
	"golang.org/x/term"
)

var maxSecretBytes = secretValueLimit()

func secretValueLimit() int {
	limit, ok := api.FieldReasonLimit("secret_value_too_large")
	if !ok {
		panic("CLI vocabulary has no secret value limit")
	}
	return limit
}

func IsTerminal(file *os.File) bool {
	return term.IsTerminal(int(file.Fd()))
}

func Line(prompt string, input io.Reader, output io.Writer) (string, error) {
	if _, err := fmt.Fprint(output, prompt); err != nil {
		return "", err
	}
	line, err := bufio.NewReader(input).ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return "", fmt.Errorf("read input: %w", err)
	}
	return strings.TrimSuffix(strings.TrimSuffix(line, "\n"), "\r"), nil
}

func Secret(prompt string, input *os.File, output io.Writer) ([]byte, error) {
	if !term.IsTerminal(int(input.Fd())) {
		return nil, errors.New("hidden input needs a terminal; use --stdin")
	}
	if _, err := fmt.Fprint(output, prompt); err != nil {
		return nil, err
	}
	oldState, err := term.GetState(int(input.Fd()))
	if err != nil {
		return nil, fmt.Errorf("read terminal state: %w", err)
	}
	interrupts := make(chan os.Signal, 1)
	signal.Notify(interrupts, os.Interrupt)
	finished := make(chan struct{})
	defer func() {
		close(finished)
		signal.Stop(interrupts)
	}()
	go func() {
		select {
		case <-interrupts:
			// Go may restart the blocking terminal read after SIGINT. Restore first, then exit
			// so an interrupted prompt cannot leave the person's shell with echo disabled.
			_ = term.Restore(int(input.Fd()), oldState)
			os.Exit(130)
		case <-finished:
		}
	}()
	value, err := term.ReadPassword(int(input.Fd()))
	if err != nil {
		clear(value)
		return nil, fmt.Errorf("read hidden input: %w", err)
	}
	if _, err := fmt.Fprintln(output); err != nil {
		return nil, err
	}
	if len(value) > maxSecretBytes {
		clear(value)
		return nil, errors.New(api.FieldReasonMessage("value", "secret_value_too_large"))
	}
	return value, nil
}

func StdinSecret(input io.Reader) ([]byte, error) {
	value, err := io.ReadAll(io.LimitReader(input, int64(maxSecretBytes)+1))
	if err != nil {
		return nil, fmt.Errorf("read secret from stdin: %w", err)
	}
	if len(value) > maxSecretBytes {
		clear(value)
		return nil, errors.New(api.FieldReasonMessage("value", "secret_value_too_large"))
	}
	return value, nil
}

func StdinToken(input io.Reader) ([]byte, error) {
	value, err := StdinSecret(input)
	if err != nil {
		return nil, err
	}
	return bytesTrimOneLineEnding(value), nil
}

func bytesTrimOneLineEnding(value []byte) []byte {
	if len(value) > 0 && value[len(value)-1] == '\n' {
		value = value[:len(value)-1]
		if len(value) > 0 && value[len(value)-1] == '\r' {
			value = value[:len(value)-1]
		}
	}
	return value
}
