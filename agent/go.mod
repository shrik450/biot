module biot/agent

// Each environment builds the agent with the Go from the nixpkgs revision it pins, so this minimum
// stays at the oldest version the code needs rather than following this repository's toolchain.
go 1.24

require github.com/creack/pty v1.1.24
