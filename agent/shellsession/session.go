package shellsession

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"slices"
	"syscall"
	"time"

	"biot/agent/protocol"
	"github.com/creack/pty"
)

const DisconnectGrace = 500 * time.Millisecond

var ErrPeer = errors.New("peer error")

var errInvalidFrame = errors.New("invalid shell frame")

func Run(connection net.Conn, input *bufio.Reader, shellEntrypoint string, request protocol.ShellRequest) error {
	command := exec.Command(shellEntrypoint, request.Command...)
	command.Env = []string{"TERM=" + request.Term}

	terminal, err := pty.StartWithSize(command, &pty.Winsize{Cols: request.Cols, Rows: request.Rows})
	if err != nil {
		return err
	}
	defer terminal.Close()

	processDone := make(chan byte, 1)
	go func() {
		processDone <- exitStatus(command.Wait())
	}()

	inputDone := make(chan error, 1)
	go func() {
		inputDone <- readInput(input, terminal)
	}()

	sessionDone := make(chan struct{})
	defer close(sessionDone)
	output := make(chan []byte)
	go readOutput(terminal, output, sessionDone)

	// A nil channel blocks forever, so `output` and `processDone` are nil once that side has
	// finished. The session ends when both have, which is the model's drain, then exit order.
	var status byte
	for {
		select {
		case inputErr := <-inputDone:
			if processDone != nil {
				terminate(command.Process.Pid, processDone)
			}
			return inputErr
		case chunk, ok := <-output:
			if !ok {
				output = nil
				if processDone == nil {
					return writeExit(connection, status)
				}
				continue
			}
			if err := protocol.WriteFrame(connection, protocol.FrameData, chunk); err != nil {
				if processDone != nil {
					terminate(command.Process.Pid, processDone)
				}
				return peerError(err)
			}
		case status = <-processDone:
			processDone = nil
			if output == nil {
				return writeExit(connection, status)
			}
		}
	}
}

func readInput(connection io.Reader, terminal *os.File) error {
	for {
		frame, err := protocol.ReadFrame(connection)
		if err != nil {
			return peerError(err)
		}

		switch frame.Type {
		case protocol.FrameData:
			if _, err := terminal.Write(frame.Payload); err != nil {
				return err
			}
		case protocol.FrameResize:
			if len(frame.Payload) != 4 {
				return peerError(errInvalidFrame)
			}
			size := &pty.Winsize{
				Cols: binary.BigEndian.Uint16(frame.Payload[0:2]),
				Rows: binary.BigEndian.Uint16(frame.Payload[2:4]),
			}
			if size.Cols == 0 || size.Rows == 0 {
				return peerError(errInvalidFrame)
			}
			if err := pty.Setsize(terminal, size); err != nil {
				return err
			}
		default:
			return peerError(errInvalidFrame)
		}
	}
}

func writeExit(connection io.Writer, status byte) error {
	if err := protocol.WriteFrame(connection, protocol.FrameExit, []byte{status}); err != nil {
		return peerError(err)
	}
	return nil
}

func peerError(err error) error {
	return fmt.Errorf("%w: %v", ErrPeer, err)
}

func readOutput(terminal io.Reader, output chan<- []byte, done <-chan struct{}) {
	defer close(output)
	buffer := make([]byte, protocol.FramePayloadLimit)
	for {
		count, err := terminal.Read(buffer)
		if count > 0 {
			select {
			case output <- slices.Clone(buffer[:count]):
			case <-done:
				return
			}
		}
		if err != nil {
			return
		}
	}
}

func terminate(processGroup int, processDone <-chan byte) {
	_ = syscall.Kill(-processGroup, syscall.SIGHUP)
	timer := time.NewTimer(DisconnectGrace)
	defer timer.Stop()

	select {
	case <-processDone:
		return
	case <-timer.C:
		_ = syscall.Kill(-processGroup, syscall.SIGKILL)
		<-processDone
	}
}

func exitStatus(err error) byte {
	if err == nil {
		return 0
	}

	var exitError *exec.ExitError
	if !errors.As(err, &exitError) {
		return 255
	}
	status, ok := exitError.Sys().(syscall.WaitStatus)
	if !ok {
		return 255
	}
	if status.Signaled() {
		return byte(128 + status.Signal())
	}
	return byte(status.ExitStatus())
}
