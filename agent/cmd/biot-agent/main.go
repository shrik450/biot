package main

import (
	"bufio"
	"errors"
	"flag"
	"log"
	"net"
	"os"

	"biot/agent/portrelay"
	"biot/agent/protocol"
	"biot/agent/shellsession"
)

func main() {
	socketPath := flag.String("socket", "", "Unix socket path")
	shellEntrypoint := flag.String("shell-entrypoint", "", "bundle shell entry point")
	flag.Parse()

	if *socketPath == "" {
		log.Fatal("socket path is required")
	}
	if *shellEntrypoint == "" {
		log.Fatal("shell entry point is required")
	}
	if err := serve(*socketPath, *shellEntrypoint); err != nil {
		log.Fatal(err)
	}
}

func serve(socketPath string, shellEntrypoint string) error {
	if err := os.Remove(socketPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}

	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		return err
	}
	defer listener.Close()
	if err := os.Chmod(socketPath, 0o666); err != nil {
		return err
	}

	for {
		connection, err := listener.Accept()
		if err != nil {
			return err
		}
		go handle(connection, shellEntrypoint)
	}
}

func handle(connection net.Conn, shellEntrypoint string) {
	defer connection.Close()

	input := protocol.NewReader(connection)
	request, err := protocol.ReadRequest(input)
	if err != nil {
		if errors.Is(err, protocol.ErrInvalidRequest) {
			_ = protocol.WriteRejected(connection, protocol.RejectionInvalidRequest)
		}
		return
	}

	switch request := request.(type) {
	case protocol.PortRequest:
		handlePort(connection, input, request)
	case protocol.ShellRequest:
		handleShell(connection, input, shellEntrypoint, request)
	}
}

func handlePort(connection net.Conn, input *bufio.Reader, request protocol.PortRequest) {
	service, err := portrelay.Connect(request.Port)
	if err != nil {
		_ = protocol.WriteRejected(connection, protocol.RejectionConnectionRefused)
		return
	}
	if err := protocol.WriteAccepted(connection); err != nil {
		service.Close()
		return
	}
	portrelay.Relay(connection, input, service)
}

func handleShell(connection net.Conn, input *bufio.Reader, shellEntrypoint string, request protocol.ShellRequest) {
	if err := protocol.WriteAccepted(connection); err != nil {
		return
	}
	if err := shellsession.Run(connection, input, shellEntrypoint, request); err != nil && !errors.Is(err, shellsession.ErrPeer) {
		log.Printf("shell session ended: %v", err)
	}
}
