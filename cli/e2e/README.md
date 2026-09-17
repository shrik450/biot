# Go CLI end-to-end tests

These tests drive the real `biot` binary against a real Phoenix server over
real HTTP. They are behind the `e2e` build tag. They never stub the API; the
only extra hop is a transparent recording proxy that forwards every request to
the real server and returns its real response.

## Stand up the server and a node

`e2e_server.exs` starts the dev server and connects a real control-protocol peer
over mutual TLS. The peer is `Biot.Server.AccessHarness.ready_peer/4`: it speaks
the real wire protocol, accepts a desired spec, reports a healthy observation
for it, accepts every secret and fetch-credential delivery, and serves a shell
stream for `biot ssh`. Nothing here reaches Nix; a node that would build an
environment is past the boundary the CLI can see. No `Biot.Server.*` module is
stubbed.

Run it from the repository root:

```sh
MIX_ENV=dev nohup mix run --no-start cli/e2e/e2e_server.exs > /tmp/biot-e2e-server.log 2>&1 &
```

It holds until killed. Once the log contains `READY`, it has printed:

```text
SERVER_URL=http://localhost:4000
TOKEN=...
SECOND_TOKEN=...
SECOND_CREDENTIAL_ID=...
SHARE_EMAIL=teammate@example.test
NODE_ID=...
BIOT_NAME=offline-...
SSH_PORT=...
READY
```

What the script seeds, all through the server's own paths:

- `TestFixtures.certificates/2` generates the authority, server, and two node
  certificates into a temp directory.
- `TestFixtures.put_registrations/1` enrolls both nodes through the operator
  file *before* startup. The startup reconciliation disables every node the
  file does not name, so an unenrolled node goes disabled moments after it is
  inserted.
- `Credentials.create/3` mints two bearer credentials for an enabled principal.
- `AccessHarness.ready_peer/4` connects the first node.
- `Biots.create/3` creates a Biot on the second node, which stays enabled but
  has no peer, so deliveries to it fail. That is the failure path the secret
  tests exercise.
- `ssh-keygen` writes a host key, and the script puts it and a free high port
  into `:biot_server` before startup so the SSH daemon runs. The dev config
  leaves both unset, exactly as it leaves the control listener unset.

It creates `/tmp/biot-e2e/` for the token file it writes; nothing needs to exist
beforehand.

The HTTP endpoint listens on `http://localhost:4000`. Use `localhost`, not
`127.0.0.1`: the control host is `localhost` and the host dispatcher answers
anything else with the preview 404 page.

## Run the suite

```sh
cd cli
log=/tmp/biot-e2e-server.log
export BIOT_E2E_SERVER=http://localhost:4000
export BIOT_E2E_TOKEN="$(grep '^TOKEN=' "$log" | cut -d= -f2)"
export BIOT_E2E_SECOND_TOKEN="$(grep '^SECOND_TOKEN=' "$log" | cut -d= -f2)"
export BIOT_E2E_SECOND_CREDENTIAL_ID="$(grep '^SECOND_CREDENTIAL_ID=' "$log" | cut -d= -f2)"
export BIOT_E2E_SHARE_EMAIL="$(grep '^SHARE_EMAIL=' "$log" | cut -d= -f2)"
export BIOT_E2E_BIOT="$(grep '^BIOT_NAME=' "$log" | cut -d= -f2)"
export BIOT_E2E_NODE="$(grep '^NODE_ID=' "$log" | cut -d= -f2)"
GOCACHE=/tmp/biot-go-cache go test -tags=e2e -count=1 -v ./e2e/
```

`TestMain` builds `./cmd/biot` into a temporary directory with
`GOCACHE=/tmp/biot-go-cache` unless `BIOT_E2E_BINARY` names an existing binary.

The tests fail loudly if an environment variable they need is missing; they do
not skip. `BIOT_E2E_BIOT` is the enabled-but-unconnected Biot used for the
failure-path checks; `BIOT_E2E_NODE` is the connected node used for create,
lifecycle, and SSH.

## The SSH test and the `ssh` wrapper

`TestSSHCommand` registers a generated public key, creates a Biot, and runs
`biot ssh <biot> --identity KEY -- echo hello`. It proves the output and the
exit status travel the whole way: the CLI execs the real `ssh` client, the
server opens a shell stream, and the peer serves it.

The external `ssh` client reads its user config from the passwd home and ignores
`$HOME`, so a test cannot point it at a temp `known_hosts` by setting `HOME`. It
would stop on the server's fresh host key. The test puts a wrapper named `ssh`
on `PATH` that runs the real `ssh` with `StrictHostKeyChecking=no` and
`UserKnownHostsFile=/dev/null`. The wrapper only relaxes a client policy; it
does not stand in for any Biot code.

## Not covered

`biot token create` and the browser half of `biot login` open a page; the suite
covers `token list`, `token revoke`, and the non-interactive
`biot login SERVER_URL` with a pasted token instead.
