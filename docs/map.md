# Repository map

## Layout

- `apps/biot_protocol` owns shared parsed values and wire codecs.
- `apps/biot_server` owns server modules, queries, policy, and the server database.
- `apps/biot_web` owns the Phoenix HTTP API and LiveView UI.
- `apps/biot_node` owns reconciliation, host effects, environment handling, and container sessions.
- `cli` contains the Go command-line client.
- `config` contains shared Mix and runtime configuration.
- `docker/linux-host` contains the Linux host image for node host tests.

The server owns authorization, durable intent, observations, and operation meaning.
The node owns host resources and reports inspected state.
The protocol app owns shared boundary values and codecs.
The web and CLI code do not own domain state.

## `apps/biot_protocol`

This app owns shared parsed values and wire codecs.

### Protocol layer

- `Message.*` defines the protocol message structs.
- `Wire` provides a versioned, strict JSON codec with table-driven dispatch.
- `Frame` encodes and incrementally decodes length-prefixed frames.
- `Version` selects the highest protocol version shared by both peers.
- `Liveness` matches heartbeat responses.
- `Platform` represents supported Linux host platforms.
- `PeerIdentity` computes certificate public-key fingerprints.
- `Certificates` and `mix biot.gen.certs` write deployment certificates and keys.
  The task writes CA, server, and node certificates, keys with mode 0600, and `fingerprints.json`.
- `OrphanedAllocation` represents node allocations absent from server intent.

### Value modules

- **Identifiers:** `CanonicalUuid` parses canonical UUID strings.
- **Sources:** `RepositorySource` represents a credential-free Git repository URL.
- **Sources:** `SourceSelector` represents an unpinned source and its ref.
- **Sources:** `PinnedSource` represents a source with a commit revision and Nix NAR hash.
- **Environment:** `EnvironmentSelection` represents the sources and project directory for an environment.
- **Environment:** `Manifest` represents resolved sources, a project snapshot, and a content digest.
- **Environment:** `ProjectSnapshot` represents a project identifier and its digest.
- **Environment:** `Digest` represents a raw SHA-256 digest with a named encoding.
- **Execution:** `Desired` represents execution intent and provides `transition/2`.
- **Execution:** `BiotSpec` contains execution and access intent for an assigned node.
- **Execution:** `ExecutionSpec` contains complete server-owned execution intent.
- **Execution:** `ExecutionReport` contains node-supplied execution facts.
- **Execution:** `Failure` represents a bounded description of a failed lifecycle action.
- **Execution:** `ContainerState` represents the observed state of a container.
- **Identifiers:** `ConnectionId` identifies an authenticated node connection.
- **Identifiers:** `IncarnationId` identifies a container incarnation.
- **Other parsed values:** `Hostname` represents a lowercase DNS label.
- **Other parsed values:** `Port` represents a valid user-facing TCP port.
- **Other parsed values:** `RelativeDirectory` represents a safe relative checkout directory.

Parsed values share `parse/1`, which returns `{:ok, t} | {:error, atom}`.
Their `to_string/1` output round-trips through `parse/1`.
`ParsedList` parses lists of values with a supplied parser.
`Failure`, `Manifest`, `EnvironmentSelection`, and `ContainerState` provide `encode/1` and `parse/1`.
Tests for this app are pure unit tests with StreamData property tests.
`test/test_helper.exs` holds the generators.

## apps/biot_server

### Layout

`Schema.*` are plain Ecto schemas with no changesets.
`Ecto.*` are custom types.
`ProtocolValue` stores any parsed protocol value as text.
The other custom types wrap protocol `encode/1` and `parse/1` functions.
`Principals` and `Nodes` own transactions.
`Nodes.Plan` is the pure enrollment planner.
`Nodes.RegistrationLoader` reads the JSON file named by `BIOT_NODE_REGISTRATIONS`.
`Nodes.Startup` runs enrollment at boot and fails boot with a readable message on rejection.
`Actor` is the authenticated caller.
`CommandError` is the model's error union.
`CommandError` includes `destroyed` for lifecycle changes against a destroyed Biot.

### Application modules

- `Biots` handles `create`, `start`, `stop`, `update_environment`, `destroy`, `get`, `list`, and `spec`.
- `Biots.Create`, `Biots.SelectEnvironment`, `Biots.Accepted`, `Biots.Unchanged`, and `Biots.CreationFingerprint` define lifecycle inputs, results, and fingerprints.
- `Operations` owns operation queries.
- `Operations.Completion` provides pure completion evidence.
- `Reports` handles node-facing ingestion through `observation`, `resolution`, and `node_observation`.
- `Queries.BiotView` and `Queries.OperationView` provide pure projections.
- `Authorization` provides pure predicates.
- `NodeConnections` is an ETS registry of current node connections written by the control link.
- `NodeWake` provides one PubSub topic per node, plus `spec_changed/2` and `subscribe/1`.

### Control protocol

- `Control.Listener` accepts mutually authenticated TLS node connections.
- `Control.Connection` owns one process per node connection.
  It handles hello, synchronize, ready, wake, reports, heartbeats, and diagnostics.
  The Registry enforces newest-wins connection replacement.
- `Control.Synchronization` builds the complete intent set for a node.
- `Diagnostics` authorizes and retrieves bounded node-held diagnostics.

### Migrations

Migrations live under `priv/repo/migrations`.
Raw SQL is used only for `biots` and `view_grants`.
SQLite needs their composite foreign keys inline.

### Tests

`test/support/data_case.ex` gives tests a sandboxed Repo.
`test/support/fixtures.ex` builds rows.
Integration tests hit the real SQLite test database.

## `apps/biot_node`

The node owns host reconciliation and reports inspected state to the server.

### Control protocol

- `Control` sends observations, resolutions, and orphaned allocation reports.
- `Control.Connection` is a reconnecting TLS client.
  Configuration gates startup, and Linux hosts are required.
- `Intents` stores specs in ETS and supports per-Biot and all-Biots subscriptions.
  Step 9 replaces this state with durable `LocalIntent` persistence.
- `Diagnostics` stores bounded node diagnostics for on-demand requests.

## Releases

The root Mix project defines two releases.
The `server` release includes `biot_protocol`, `biot_server`, and `biot_web`.
The `node` release includes `biot_protocol` and `biot_node`.

Build them with `MIX_ENV=prod mix release server` and `MIX_ENV=prod mix release node`.

## Tooling

`.mise.toml` pins Erlang 28.5 and Elixir 1.20.4 with OTP 28.
Run Elixir commands through mise:

```sh
mise exec -- mix deps.get
mise exec -- mix check
mise exec -- mix test
```

`mix check` runs format checks, Credo in strict mode, and compilation with warnings as errors.

Build and vet the CLI with:

```sh
cd cli
go build ./...
go vet ./...
```

## CI

`.github/workflows/ci.yml` installs Nix, checks Podman, and sets up Erlang 28.5, Elixir 1.20.4, and Go 1.26.x.
It runs `mix deps.get`, `mix check`, `mix test`, `go build ./...`, and `go vet ./...`.

## Configuration and tests

`config/test.exs` uses `_build/test/biot_server_test.sqlite3` and the Ecto SQL sandbox.
`config/runtime.exs` reads `SECRET_KEY_BASE`, `PHX_HOST`, and `PORT` in production.

## Host tests in Docker

Build the Linux host image, then run host tests with privileged access:

```sh
docker build -t biot-linux-host docker/linux-host
docker run --privileged --rm -it biot-linux-host
```

Run the full suite on Linux with `docker/linux-host/run-tests.sh` from the repository root.
