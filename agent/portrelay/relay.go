package portrelay

import (
	"fmt"
	"io"
	"net"
)

func Connect(port uint16) (net.Conn, error) {
	return net.Dial("tcp4", fmt.Sprintf("127.0.0.1:%d", port))
}

func Relay(peer net.Conn, peerInput io.Reader, service net.Conn) {
	done := make(chan struct{}, 2)
	copyBytes := func(destination net.Conn, source net.Conn) {
		_, _ = io.Copy(destination, source)
		done <- struct{}{}
	}

	go func() {
		_, _ = io.Copy(service, peerInput)
		done <- struct{}{}
	}()
	go copyBytes(peer, service)
	<-done
	_ = peer.Close()
	_ = service.Close()
	<-done
}
