package protocol

import (
	"encoding/binary"
	"errors"
	"io"
)

const FramePayloadLimit = 64 * 1024

const (
	FrameData   byte = 0
	FrameResize byte = 1
	FrameExit   byte = 2
)

var ErrFrameTooLarge = errors.New("frame payload too large")

type Frame struct {
	Type    byte
	Payload []byte
}

func ReadFrame(reader io.Reader) (Frame, error) {
	header := [5]byte{}
	if _, err := io.ReadFull(reader, header[:]); err != nil {
		return Frame{}, err
	}

	length := binary.BigEndian.Uint32(header[1:])
	if length > FramePayloadLimit {
		return Frame{}, ErrFrameTooLarge
	}

	payload := make([]byte, int(length))
	if _, err := io.ReadFull(reader, payload); err != nil {
		return Frame{}, err
	}
	return Frame{Type: header[0], Payload: payload}, nil
}

func WriteFrame(writer io.Writer, frameType byte, payload []byte) error {
	if len(payload) > FramePayloadLimit {
		return ErrFrameTooLarge
	}

	header := [5]byte{frameType}
	binary.BigEndian.PutUint32(header[1:], uint32(len(payload)))
	if _, err := writer.Write(header[:]); err != nil {
		return err
	}
	_, err := writer.Write(payload)
	return err
}
