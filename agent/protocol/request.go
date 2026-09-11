package protocol

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
)

const LineLimit = 16 * 1024

var ErrInvalidRequest = errors.New("invalid request")

// Rejection is the closed set of reasons a target is refused.
type Rejection string

const (
	RejectionInvalidRequest    Rejection = "invalid_request"
	RejectionConnectionRefused Rejection = "connection_refused"
)

// Request is the target a connection carries. The unexported method closes the set to the
// two types below.
type Request interface {
	isRequest()
}

type PortRequest struct {
	Port uint16
}

func (PortRequest) isRequest() {}

type ShellRequest struct {
	Term    string
	Cols    uint16
	Rows    uint16
	Command []string
}

func (ShellRequest) isRequest() {}

// The buffer size is the line bound: ReadSlice fails with ErrBufferFull on a longer line, which
// closes the stream.
func NewReader(connection io.Reader) *bufio.Reader {
	return bufio.NewReaderSize(connection, LineLimit)
}

func ReadRequest(reader *bufio.Reader) (Request, error) {
	line, err := reader.ReadSlice('\n')
	if err != nil {
		return nil, err
	}

	var fields map[string]json.RawMessage
	if err := json.Unmarshal(bytes.TrimSuffix(line, []byte{'\n'}), &fields); err != nil {
		return nil, ErrInvalidRequest
	}

	var target string
	if err := json.Unmarshal(fields["target"], &target); err != nil {
		return nil, ErrInvalidRequest
	}

	switch target {
	case "port":
		return parsePort(fields)
	case "shell":
		return parseShell(fields)
	default:
		return nil, ErrInvalidRequest
	}
}

func WriteAccepted(writer io.Writer) error {
	return writeReply(writer, reply{OK: true})
}

func WriteRejected(writer io.Writer, rejection Rejection) error {
	return writeReply(writer, reply{Error: string(rejection)})
}

type reply struct {
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
}

func writeReply(writer io.Writer, value reply) error {
	encoded, err := json.Marshal(value)
	if err != nil {
		return err
	}
	encoded = append(encoded, '\n')
	_, err = writer.Write(encoded)
	return err
}

func parsePort(fields map[string]json.RawMessage) (PortRequest, error) {
	if !hasExactFields(fields, "target", "port") {
		return PortRequest{}, ErrInvalidRequest
	}

	var port uint16
	if err := json.Unmarshal(fields["port"], &port); err != nil || port == 0 {
		return PortRequest{}, ErrInvalidRequest
	}
	return PortRequest{Port: port}, nil
}

func parseShell(fields map[string]json.RawMessage) (ShellRequest, error) {
	if !hasExactFields(fields, "target", "term", "cols", "rows", "command") {
		return ShellRequest{}, ErrInvalidRequest
	}

	request := ShellRequest{}
	if err := json.Unmarshal(fields["term"], &request.Term); err != nil || request.Term == "" || bytes.IndexByte([]byte(request.Term), 0) >= 0 {
		return ShellRequest{}, ErrInvalidRequest
	}
	if err := json.Unmarshal(fields["cols"], &request.Cols); err != nil || request.Cols == 0 {
		return ShellRequest{}, ErrInvalidRequest
	}
	if err := json.Unmarshal(fields["rows"], &request.Rows); err != nil || request.Rows == 0 {
		return ShellRequest{}, ErrInvalidRequest
	}
	if !bytes.Equal(fields["command"], []byte("null")) {
		if err := json.Unmarshal(fields["command"], &request.Command); err != nil || len(request.Command) == 0 {
			return ShellRequest{}, ErrInvalidRequest
		}
		for _, argument := range request.Command {
			if bytes.IndexByte([]byte(argument), 0) >= 0 {
				return ShellRequest{}, ErrInvalidRequest
			}
		}
	}
	return request, nil
}

func hasExactFields(fields map[string]json.RawMessage, names ...string) bool {
	if len(fields) != len(names) {
		return false
	}
	for _, name := range names {
		if _, ok := fields[name]; !ok {
			return false
		}
	}
	return true
}
