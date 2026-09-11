package protocol

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"testing"
)

func TestFramePayloadBoundAndRoundTrip(t *testing.T) {
	payload := bytes.Repeat([]byte("x"), FramePayloadLimit)
	var encoded bytes.Buffer
	if err := WriteFrame(&encoded, FrameData, payload); err != nil {
		t.Fatal(err)
	}
	frame, err := ReadFrame(&encoded)
	if err != nil {
		t.Fatal(err)
	}
	if frame.Type != FrameData || !bytes.Equal(frame.Payload, payload) {
		t.Fatal("exact-bound frame did not round trip")
	}
	if err := WriteFrame(io.Discard, FrameData, append(payload, 'x')); !errors.Is(err, ErrFrameTooLarge) {
		t.Fatalf("oversized WriteFrame error = %v", err)
	}
}

func TestReadFrameRejectsOversizeBeforeReadingPayload(t *testing.T) {
	header := [5]byte{FrameData}
	binary.BigEndian.PutUint32(header[1:], FramePayloadLimit+1)
	reader := &headerOnlyReader{header: header[:]}
	if _, err := ReadFrame(reader); !errors.Is(err, ErrFrameTooLarge) {
		t.Fatalf("ReadFrame error = %v", err)
	}
	if reader.payloadRead {
		t.Fatal("ReadFrame read payload bytes after an oversized header")
	}
}

func FuzzReadFrame(f *testing.F) {
	f.Add([]byte{})
	f.Add([]byte{FrameData, 0, 0, 0, 0})
	f.Add([]byte{FrameExit, 0, 0, 0, 1, 7})
	f.Fuzz(func(t *testing.T, input []byte) {
		_, _ = ReadFrame(bytes.NewReader(input))
	})
}

func FuzzFrameRoundTrip(f *testing.F) {
	f.Add(FrameData, []byte("hello"))
	f.Add(FrameResize, []byte{0, 80, 0, 24})
	f.Fuzz(func(t *testing.T, frameType byte, payload []byte) {
		if len(payload) > FramePayloadLimit {
			t.Skip()
		}
		var encoded bytes.Buffer
		if err := WriteFrame(&encoded, frameType, payload); err != nil {
			t.Fatal(err)
		}
		frame, err := ReadFrame(&encoded)
		if err != nil {
			t.Fatal(err)
		}
		if frame.Type != frameType || !bytes.Equal(frame.Payload, payload) {
			t.Fatalf("round trip = %#v", frame)
		}
	})
}

type headerOnlyReader struct {
	header      []byte
	payloadRead bool
}

func (reader *headerOnlyReader) Read(destination []byte) (int, error) {
	if len(reader.header) > 0 {
		count := copy(destination, reader.header)
		reader.header = reader.header[count:]
		return count, nil
	}
	reader.payloadRead = true
	return 0, io.EOF
}
