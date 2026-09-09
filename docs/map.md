# Repository map

## Layout

- `apps/biot_protocol` owns shared parsed values and wire codecs.
- `apps/biot_server` owns server modules, queries, policy, and the server database.
- `apps/biot_web` owns the Phoenix HTTP API and LiveView UI.
- `apps/biot_node` owns reconciliation, host effects, environment handling, and container sessions.
- `nix/` owns the module schema, the `build.nix` entry point, and example layers. `nix/README.md` holds the build contract for the node host layer.
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
  Its stages include `release_environment`; its codes include `invalid_configuration`
  and `ownership_mismatch`.
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

#### `Biot.Server.Publications`

`publish/3` adds one published port and its derived hostname. `unpublish/3`
withdraws the publication and its view grants. `discover/2` returns the owner's
or a shell-grant holder's published URLs. Each mutation returns a
`Policy.Applied` result when it changes records, or a `Policy.Unchanged` result
when the requested policy already exists. Both result structs carry the Biot ID,
access revision, and `enforcement`.

#### `Biot.Server.Access`

`grant_shell/3` and `revoke_shell/3` manage Biot shell grants.
`grant_view/4` and `revoke_view/4` manage a principal's access to one published
port. `get_grants/2` returns the owner and explicit grants for the Biot. Mutation
results use `Policy.Applied` or `Policy.Unchanged`, with the same `enforcement`
field. Grants require known principals; view grants require a publication for the
same Biot and port.

#### `Biot.Server.Policy`

`Policy.Applied` and `Policy.Unchanged` are the two successful policy results.
`Policy.enforcement()` is `:applied` or `{:pending, node_id}`.
`Policy.Transaction` owns the immediate transaction around each mutation. It
loads the Biot, authorizes the actor, checks that the Biot is not destroyed,
executes the callback's writes, bumps the access revision on withdrawal, wakes
the node after a withdrawal, reads enforcement from committed observation and
connection state, and builds the result.

Policy callbacks receive the transaction's repository and Biot. They return
`:unchanged`, `{:added, multi}`, or `{:withdrawn, multi}`. Additions keep the
current revision and do not wake the node. Withdrawals add one revision and wake
the assigned node.

`Policy.Enforcement.freshness/2` compares an observation's connection with the
node's current connection. `access/3` reports `:applied` only for a current
observation that has caught up to the Biot's access revision. Otherwise it
reports `{:pending, node_id}`. `Policy.Enforcement` supplies this same result to
policy commands and `Queries.BiotView`.

#### Hostnames and projections

`Publications.HostnameDerivation` builds each hostname from a version byte, the
16 UUID bytes, and the port as a big-endian unsigned 16-bit integer. It signs
that input with HMAC-SHA-256, keeps the first 128 bits, and encodes them as
lowercase, unpadded base32. The server stores the derived label on the active
publication row. The URL format is `https://<hostname>.<domain>`.

`publication_hmac_key` reads `BIOT_SERVER_PUBLICATION_HMAC_KEY` in production.
`publication_domain` reads `BIOT_SERVER_PUBLICATION_DOMAIN`. The key and domain
are server configuration; the key and derivation version must remain durable
for URL stability.

`Queries.PublicationView` sorts publications by port and projects each row into
its port and HTTPS URL. `Queries.AccessView` projects loaded shell and view rows
into the owner ID, sorted shell principal IDs, and sorted `{port, principal_id}`
view grants. `Queries.BiotView` uses `Policy.Enforcement` for the access status
shown with the rest of the Biot view.

`Authorization.may_change_policy?/2` permits policy mutations for the owner.
`Authorization.may_discover?/3` permits discovery for the owner or a principal
in the loaded shell-grant IDs. `may_read_grants?/2` remains owner-only.

These modules follow the model contract. Additions never move the access
revision. Unpublish relies on the view-grant foreign-key cascade. A
`hostname_conflict` returns an error and never routes to the existing
publication.

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

Step 10 adds focused server evidence:

- `policy/enforcement_test.exs` proves current-connection freshness and access
  enforcement for missing, stale, and caught-up observations.
- `publications/hostname_derivation_test.exs` proves fixed derivation vectors,
  valid stable labels, and sensitivity to the key, Biot ID, port, and version.
- `queries/publication_view_test.exs` proves HTTPS URL projection, port sorting,
  and empty-list handling.
- `queries/access_view_test.exs` proves owner projection and deterministic shell
  and view grant ordering, including empty lists.
- `queries/biot_view_test.exs` proves the product view uses current connection
  state for node and access status.
- `queries/operation_view_test.exs` proves operation kinds and outcomes remain
  unchanged in the projection, including failures.
- `policy_records_test.exs` uses real SQLite transactions to prove policy
  idempotence, authorization, revision and wake behavior, destroyed checks,
  view-grant cascades, hostname conflicts, and enforcement progress.
- `authorization_test.exs` proves owner, policy-change, grant-read, and
  discovery predicates.

## `apps/biot_node`

The node owns host reconciliation and reports inspected state to the server.

### Node state and reconciliation

- `Biot.Node.NodeState` is the derived view for one Biot. It holds `data`, a `resolutions`
  map keyed by environment ID, `installation`, and a `container` with its
  `biot_id`.
- `Biot.Node.Host.inspect_state/2` returns the five host facts in `Host.Inspection`.
  The controller owns `pending_exit` and `failure`, then builds `NodeState` from all
  seven values.
- `Biot.Node.Reconcile.next/4` returns `:settled`, `{:run, action}`, `:cancel_current`,
  `{:blocked, reason}`, or `{:failed, failure}`.
- Its gates run in order: current action, recorded failure, convergence, and the
  offline control gate. `Reconcile.Data`, `Reconcile.Environment`, and
  `Reconcile.Execution` compose the decisions.
- `Reconcile.Environment.release/2` releases unretained environment resources.
  Ordinary convergence runs data, environment, execution, then release.
  Destruction runs execution, release, then data.
- `Biot.Node.Action.metadata/1` centralizes each action's stage, cancellation rule, control
  requirement, and environment use. `requires_control?/1` identifies the four
  actions that need a live control link.
- `BlockReason` describes inspection, an in-flight action, a recorded failure, or
  offline control. `Retry.classify/4` maps host outcomes to bounded failures and
  retry policies; `Retry.failure/2` builds failures found without an action.
- `InspectionFailure` keeps an unreadable resource distinct from an absent one.

#### BiotController

`Biot.Node.BiotController` owns one Biot. It loads the current `LocalIntent` from
`Biot.Node.Journal`, inspects the host, reports the inspection, asks
`Reconcile.next/4` for one action, and runs that action in one linked effect task.
After the task returns, it records the outcome and inspects again before making
another decision. It reports every inspection, including a settled one, so the
server can learn about a container that exits on its own.

The controller's `phase` makes its waiting state explicit:

```text
:idle
{:running, effect}
{:cancelling, effect, wake}
{:backing_off, wake}
{:waiting, reason, wake}
{:settled, wake}
```

`:idle` waits for intent or synchronization. `:running` has one host effect in
flight. `:cancelling` waits for the cancellation grace period before killing an
effect that did not stop. `:backing_off` waits for an automatic retry.
`:waiting` retries an inspection block. `:settled` re-inspects on the observation
interval.

A new desired revision clears the recorded failure, attempt counts, pending
container exit, and stale backoff, inspection, or settled wake. It never clears
a running effect or its cancellation wake. A changed intent therefore cancels
obsolete work, then lets inspection determine what that work left behind.

The controller and its effect task share a failure group. A task crash takes down
the controller, and the supervisor restarts it. Restart loads durable intent and
inspects owned resources before it asks reconciliation to issue any action.

#### Controllers

`Biot.Node.Controllers` supervises the controller set. Its `Registry` uses the
opaque `BiotId` as each controller's key, and its `DynamicSupervisor` runs one
`BiotController` per Biot. `Controllers.Starter` is a long-lived bootstrap
process. It starts a controller for every durable journal intent at boot and
retries a failed start with one bounded timer per Biot.

The public API is `intent_changed/1` and `synchronized/1`. The first starts or
pokes one controller and schedules a starter retry when it cannot start. The
second receives the complete synchronized Biot ID set, starts or pokes every
announced controller, and pokes controllers absent from that set so they stop.
The controller tree uses `:rest_for_one`: the Registry starts first, the
DynamicSupervisor second, and the Starter last.

#### Pure controller support

`Biot.Node.Observation.node_state/4` combines host inspection with the
controller's pending container exit and recorded failure. `Observation.report/2`
projects the inspected state into the server's `ExecutionReport`.

`Biot.Node.Backoff.delay/3` doubles the minimum delay per attempt and caps it at
the configured maximum. `Biot.Node.Orphans.detect/2` compares journal
allocations with local intents and returns allocations absent from server intent.
It does not adopt or delete them. `Biot.Node.Retry.with_budget/3` changes an
automatic failure to an operator failure at the retry budget; other retry
policies stay unchanged.

### Node records and values

- `Allocation` records a Biot's UID/GID range, private data root, network, and
  initialization marker.
- `Installation` selects the prepared artifact used by an allocation.
  `Resolution` records one environment's manifest and snapshot path.
  `LocalIntent` stores the last accepted `BiotSpec` for one Biot.
- `NodePrivatePath`, `MarkerId`, `NetworkId`, and `ArtifactId` are node-owned
  parsed values for private paths, initialization markers, networks, and artifacts.
- `Biot.Node.StorePath` parses one canonical path at or inside a Nix store object.
- `Biot.Node.EnvironmentBundle` parses the format 1 gate and its four store
  paths. It returns `:invalid_format` for a malformed shape or path and
  `:unsupported_format` for another numeric format.

### Host layer

`Biot.Node.Host` is the plain inspection and effect boundary called by reconciliation.
`inspect_state/2` accepts a Biot ID and `Host.Context`, and returns `Host.Inspection`
with five host facts: `data`, `resolutions`, `installation`, `container`, and
`prepared`. The controller owns `pending_exit` and `failure`, and builds the
`NodeState` that reconciliation consumes. `run/2` returns `:ok | {:error,
Host.Outcome.t()}` and dispatches totally over every `Biot.Node.Action` variant.

The effect modules own host resources:

- `Host.Allocation` creates or repairs an allocation, its network, checkout, mounts,
  root filesystem, and initialization marker. It also removes data and releases the
  allocation.
- `Host.Environment` resolves sources, persists manifests, builds bundles, records
  installations, and releases environment resources.
- `Host.Container` starts and retires rootless Podman containers. `Host.Network`
  creates, inspects, and removes their named private networks.
- `Host.SourceResolver` pins Nixpkgs and Git selectors through the configured Nix
  boundary and returns resolved source values.

Pure derivations keep host facts separate from effects:

- `Host.DataInspection` derives allocation data state from journal ownership and
  filesystem facts.
- `Host.EnvironmentInspection` derives resolution, prepared-artifact, and
  installation states.
- `Host.ContainerInspection` parses Podman JSON into the owned container value.
- `Host.Outcome` maps expected effect failures and bounded command diagnostics to
  retry reasons.

Support modules provide the smaller boundaries:

- `Host.Command` runs one executable through `setsid` with a timeout and bounded
  stdout and stderr. Its handshake announces the process group, registers that
  group with `Host.Command.Reaper`, sends the go line, and then lets the shell
  `exec` the command. No command runs before the reaper owns its group.
  `Host.Podman` adds the configured Podman module and recognizes absent resources.
- `Host.Paths` owns every node-private path. Its moduledoc is the authority for
  the data-root layout. In one line: the root holds node-wide coordination and
  configuration plus per-Biot writable data and per-environment build state.
- `Host.Names` derives stable network and container names and ownership labels.
  `Host.FileSystem` provides tri-state inspection, atomic writes, and tree removal.
- `Host.Config` parses and validates operator settings. `Host.Context` binds that
  configuration to one Biot ID, and `Host.Setup` creates the node-wide directories
  and Podman configuration.

`Host.Command.Reaper` monitors the command caller. It ends the whole process
group and removes the stderr file when the caller dies. Normal completion calls
`release/1`; cancellation calls `cancel/1` and ends the group immediately. The
handshake keeps the group unstarted until the reaper has registered it, so a
caller killed between the announcement and the go line cannot leave a command
running without an owner.

### Node journal

`Biot.Node.Repo` is the Ecto SQLite repository, and `Biot.Node.Journal` is the
node-local domain API. The journal schemas are
`Journal.Schema.Allocation`, `Installation`, `Resolution`, and `LocalIntent`.
`Journal.Ecto.ParsedValue` stores canonical parsed values as strings, while
`Journal.Ecto.Manifest` and `Journal.Ecto.BiotSpec` store validated JSON values.
`Journal.Migrator` runs `priv/repo/migrations/20260909000100_create_node_journal.exs`.

Journal queries scope resolution and installation reads and writes by Biot ID,
then check environment ownership before cross-resource changes. Its ownership
transactions use SQLite immediate mode. SQLite foreign keys restrict allocation
deletion while an installation or resolution remains, and the journal also checks
that no such records remain before release. `next_uid_start/3` finds the first
unused configured range, while the unique `allocation_uid_start` index closes the
concurrent-insert race.

`Journal.put_intent/1` upserts one durable `LocalIntent` for a Biot. The control
connection uses it for an individual desired message. `Journal.replace_intents/1`
upserts the complete synchronized set in one transaction and deletes local intents
that the server no longer sends. That deletion stops the controller, leaving any
allocation for orphan reporting.

`Biot.Node.DataRootLock` owns a long-lived `flock` port on the data-root lock file.
`application.ex` always starts `Diagnostics` and `Host.Command.Reaper` first.
When host configuration exists, it then starts `DataRootLock`, `Host.Setup`,
`Repo`, journal migration, `Controllers`, and finally the configured control
connection. The lock exists before setup or journal access, and the connection
starts after the journal and controller tree are ready. Without host
configuration, the node starts neither controllers nor a control connection.

### Environment artifact

The Nix environment artifact turns one resolved manifest into an immutable
launch bundle. The schema accepts `biot.packages`, `biot.environment`,
`biot.files`, and `biot.services.<name>`. A service declares `command`,
`directory`, `environment`, and `restart`.

The types and defaults live in `nix/module.nix`. Its `assertions` option keeps
cross-field rules such as reserved environment names and safe relative paths
with the schema. Compatible module definitions merge; conflicting definitions
fail with their source locations.

`nix/build.nix` reads manifest JSON and writes bundle JSON. The manifest has the
exact `base_nixpkgs`, `digest`, `layers`, and `project_snapshot` fields. The
bundle reports `format`, `closure_root`, `entrypoint`, `environment_file`, and
`config_root`. The node retains the output link as the garbage collection root.
`nix/pin.nix` is the source-resolution artifact: `Host.SourceResolver` invokes
`nix-instantiate --eval --strict --json` with it, and it uses `builtins.fetchGit` to
return each source revision and NAR hash.

The entry point loads the generated environment and starts `supervisord`. The
runner fits several services and the `always`, `on-failure`, and `never` restart
rules without root or an init system. The bundle does not create a control
socket.

The container uses an empty, read-only root filesystem with read-only
`/nix/store`. It mounts writable `/biot/checkout`, `/biot/home`, and
`/biot/service-data`. The no-base-image invariant keeps all executables in the
Nix store and makes missing private mounts fail instead of creating temporary
state.

The `stateful-counter` example composes base and service layers. Its service
keeps a counter below the service data mount and serves the declared message
file. `nix/examples/conflicting-layer` changes the same environment value and
shows the module conflict error when added as a third layer.

Nix integration tests use the `:nix` tag. Mix excludes tests tagged `:linux`
outside Linux and tests tagged `:nix` when `nix` is not on `PATH`. The suite
checks manifest errors, store paths, bundle paths, module conflicts, reserved
variables, NAR hashes, mounts, and state across a container restart.

### Node configuration

`config/config.exs` supplies node defaults. The controller and diagnostic
settings are:

| Key | Default | Production override |
| --- | ---: | --- |
| `retry_budget` | `5` | `BIOT_NODE_RETRY_BUDGET` |
| `retry_backoff_min_ms` | `2_000` | `BIOT_NODE_RETRY_BACKOFF_MIN_MS` |
| `retry_backoff_max_ms` | `300_000` | `BIOT_NODE_RETRY_BACKOFF_MAX_MS` |
| `observation_interval_ms` | `30_000` | `BIOT_NODE_OBSERVATION_INTERVAL_MS` |
| `inspection_retry_ms` | `15_000` | `BIOT_NODE_INSPECTION_RETRY_MS` |
| `cancel_grace_ms` | `10_000` | `BIOT_NODE_CANCEL_GRACE_MS` |
| `controller_start_retry_ms` | `5_000` | `BIOT_NODE_CONTROLLER_START_RETRY_MS` |
| `diagnostic_max_entries_per_biot` | `5` | `BIOT_NODE_DIAGNOSTIC_MAX_ENTRIES_PER_BIOT` |
| `diagnostic_max_entry_bytes` | `65_536` | `BIOT_NODE_DIAGNOSTIC_MAX_ENTRY_BYTES` |

`config/runtime.exs` also reads the data root, UID/GID range, executable,
connection, heartbeat, reconnect, Nix, Podman, and TLS settings. The listed
`BIOT_NODE_*` overrides must be positive integers. `Host.Config` validates the
resulting settings before host setup or effects use them.

### Diagnostics and control

`Biot.Node.Diagnostics` keeps a bounded in-memory log for failed revisions. One
writer process owns the per-Biot revision index and writes diagnostic entries to
protected ETS. It keeps the latest failed attempt for a revision, limits each
entry by `diagnostic_max_entry_bytes`, and evicts old revisions after
`diagnostic_max_entries_per_biot`. `fetch/2` reads ETS directly, applies the
caller's byte limit, and returns whether content was truncated. `forget/1`
drops every entry for a Biot that loses local intent.

`Biot.Node.Control.Outbox` coalesces reports in ETS. It keys observations by
Biot, resolutions by environment, and the node observation as one node-wide
entry. A single wakeup marker prevents duplicate connection wakeups. The
connection drains the outbox after it acknowledges `synchronized` and whenever
a report wakes it. `Control` sends observations, resolutions, and orphaned
allocation reports to the outbox; `Control.status/0` returns `:ready` or
`:offline` from the connection's published status.

`Control.Connection` owns the reconnecting mutually authenticated TLS client,
synchronization, heartbeats, and report delivery. An individual desired message
uses `Journal.put_intent/1`; a complete synchronization uses
`Journal.replace_intents/1` before the node acknowledges synchronization. After
that acknowledgement, the connection starts or pokes controllers, compares
journal allocations with the synchronized intents, and puts orphan reports in
the outbox. The application starts this connection only after host configuration,
the journal, and the controller tree are ready. Linux is required for the node
control path.

### Tests

`test/test_helper.exs` excludes `:linux` tests outside Linux and `:nix` tests when
`nix` is unavailable. The existing host tests cover host derivations, journal
ownership, and real Linux effects. Step 9 adds focused evidence for the node
imperative shell:

- `controller_pure_test.exs` proves the `Observation`, `Backoff`, `Orphans`, and
  `Retry.with_budget/3` projections and retry rules.
- `diagnostics_integration_test.exs` uses the real diagnostics process and ETS to
  prove byte bounds, same-revision replacement, per-Biot eviction, and
  `forget/1`.
- `host_command_ownership_test.exs` uses real Linux processes to prove that a
  caller killed during the handshake starts no command, and that cancellation
  removes the whole process group promptly.
- `biot_controller_linux_integration_test.exs` runs a real server and node. Its
  `step9_controller_runner.exs` support runner proves lost-response recovery,
  controller startup and retry, cancellation, reconnect behavior, and orphan
  reporting against real resources.

`docker/linux-host/run-tests.sh` builds or reuses the privileged Linux test image
and runs the full Mix test suite inside it.

## Releases

The root Mix project defines two releases.
The `server` release includes `biot_protocol`, `biot_server`, and `biot_web`.
The `node` release includes `biot_protocol` and `biot_node`.

Build them with `MIX_ENV=prod mix release server` and `MIX_ENV=prod mix release node`.

## Tooling

`docker/linux-host/Dockerfile` includes `nftables` for rootless named Podman
networks and uses `usermod` to assign subordinate user and group IDs.
`/result` and `/result-*` are ignored.

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
`config/runtime.exs` also reads node data-root, UID-range, command, Nix, Podman,
and control settings for the production node release.

## Host tests in Docker

Build the Linux host image, then run host tests with privileged access:

```sh
docker build -t biot-linux-host docker/linux-host
docker run --privileged --rm -it biot-linux-host
```

Run the full suite on Linux with `docker/linux-host/run-tests.sh` from the repository root.
