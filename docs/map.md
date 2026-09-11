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
- `agent/` contains the Go agent and its vendored dependencies.

The server owns authorization, durable intent, observations, and operation meaning.
The node owns host resources and reports inspected state.
The protocol app owns shared boundary values and codecs.
The web and CLI code do not own domain state.

## `agent/`

The Go agent has four packages:

- `cmd/biot-agent` owns the Unix socket listener, request dispatch, stale-socket replacement, and
  accepted or rejected replies.
- `protocol` owns the closed `Request` set (`PortRequest` and `ShellRequest`), the `Rejection` set,
  and the wire bounds: request lines are limited to 16 KiB and frame payloads to 64 KiB. Its two
  required command-line values are `--socket` and `--shell-entrypoint`.
- `portrelay` connects a port target to `127.0.0.1:<port>` and relays until either side closes.
- `shellsession` owns the PTY, data and resize frames, and exit status. It drains output before
  sending the exit frame, then waits for the process and closes the session. A disconnected shell
  gets `SIGHUP`, waits `DisconnectGrace`, then gets `SIGKILL` if needed.

The PTY implementation is vendored under `agent/vendor/`. The agent starts with a clean environment;
its shell entrypoint supplies the terminal value and the bundle supplies the socket and entrypoint
paths.

## `apps/biot_protocol`

This app owns shared parsed values and wire codecs.

### Protocol layer

- `Message.*` defines the protocol message structs. Version 1 includes `RuntimeLogs(request_id, biot_id, max_bytes, timeout_ms)` and `RuntimeLogsResult(request_id, result)`. A found result carries an incarnation ID, content, and truncation flag.
- `Wire` lists both runtime-log messages in the version 1 table. Their request pair follows the diagnostic pattern. The node returns the caller's request ID with bounded content or `:not_found`.
- `Wire` provides a versioned, strict JSON codec with table-driven dispatch. It enforces the 256 KiB version 1 `BiotSpec` bound on encode and decode with `:biot_spec_too_large`. It measures the envelope of every spec-carrying message. It owns `min_frame_bytes/1` and `check_frame_limit!/1`. Both applications call the frame check at boot.
- `Frame` encodes and incrementally decodes length-prefixed frames.
- `Version` selects the highest protocol version shared by both peers.
- `Liveness` matches heartbeat responses.
- `Platform` represents supported Linux host platforms.
- `PeerIdentity` computes certificate public-key fingerprints.
- `Certificates` and `mix biot.gen.certs` write deployment certificates and keys.
  The task writes CA, server, and node certificates, keys with mode 0600, and `fingerprints.json`.
- `OrphanedAllocation` represents node allocations absent from server intent.
- `Limits` owns the versioned spec bound and the shared component limits. Version 1 allows a 256 KiB spec, a 2,048-byte repository URL, a 256-byte source ref, a 1,024-byte relative directory, and 16 layers.

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
  Its stages include `node` and `release_environment`; its codes include `node_abandoned`,
  `invalid_configuration`, and `ownership_mismatch`.
- **Execution:** `ContainerState` represents the observed state of a container.
- **Identifiers:** `ConnectionId` identifies an authenticated node connection.
- **Identifiers:** `IncarnationId` identifies a container incarnation.
- **Other parsed values:** `Hostname` represents a lowercase DNS label.
- **Other parsed values:** `Port` represents a valid user-facing TCP port.
- **Other parsed values:** `RelativeDirectory` represents a safe relative checkout directory.

`RepositorySource`, `SourceSelector`, `RelativeDirectory`, and `EnvironmentSelection` enforce the shared limits. They return `:repository_url_too_long`, `:source_ref_too_long`, `:directory_too_long`, and `:too_many_layers` for those bound violations. `EnvironmentSelection` passes through component parser reasons.

Parsed values share `parse/1`, which returns `{:ok, t} | {:error, atom}`.
Their `to_string/1` output round-trips through `parse/1`.
`ParsedList` parses lists of values with a supplied parser.
`Failure`, `Manifest`, `EnvironmentSelection`, and `ContainerState` provide `encode/1` and `parse/1`.
Tests for this app are pure unit tests with StreamData property tests.
`test/test_helper.exs` holds the generators.
`test/control_protocol_test.exs` covers the version 1 runtime-log request pair and malformed result shapes.

## apps/biot_server

### Layout

`Schema.*` are plain Ecto schemas with no changesets.
`Ecto.*` are custom types.
`ProtocolValue` stores any parsed protocol value as text.
The other custom types wrap protocol `encode/1` and `parse/1` functions.
`Principals` and `Nodes` own transactions.
`Nodes.reload/0` is the one enrollment entry point.
`Nodes.Startup` calls it at boot and fails boot with a readable message on rejection.
Operators call it with `bin/server rpc "Biot.Server.Nodes.reload()"`.
It loads the enrollment file, runs the enrollment transaction, and closes planned control connections after commit.
An invalid reload changes nothing and logs a plain failure message.
`Nodes.abandonment_failure/0` builds the only abandonment failure value.
`Biots` writes it when destroy runs on an abandoned node.
`Nodes.Plan` is the pure enrollment planner.
It returns `%Plan{writes, close_connections}`.
Its writes include `insert`, `update_status`, `update_max_biots`, `replace_peer_identity`, `increment_access_revisions`, and `fail_operations`.
Its rejections include `duplicate_node`, `duplicate_registration`, `duplicate_peer_identity`, `rebinding`, `terminal_node_locked`, and `retirement_blocked`.
`terminal_node_locked` replaces the two retired-node rejections.
Peer identity changes are allowed.
`rebinding` covers only a changed registration ID or reuse of another node's identity.
`Nodes.Status` owns the meaning of node status.
Its six functions are `terminal?/1`, `serves_access?/1`, `written_off?/1`, `accepts_connection/1`, `accepts_new_biots/1`, and `accepts_lifecycle_change/1`.
Every status appears in every function.
A new status cannot compile until all six functions answer it.
`Nodes.RegistrationLoader` reads the JSON file named by `BIOT_NODE_REGISTRATIONS`.
`Actor` is the authenticated caller.
`CommandError` is the model's error union.
`CommandError` includes `destroyed` for lifecycle changes against a destroyed Biot.

### Application modules

- `Biots` handles `create`, `start`, `stop`, `update_environment`, `destroy`, and `spec`. `spec/1` is the node-facing intent query.
- `Biots.Create`, `Biots.SelectEnvironment`, `Biots.Accepted`, `Biots.Unchanged`, and `Biots.CreationFingerprint` define lifecycle inputs, results, and fingerprints. `Create.initial_state` defaults to `:running`, and the fingerprint uses `:biot_creation_v2`.
- `Biots.Capacity.room?/2` admits creation, and `counts/2` projects capacity held on assigned nodes. Together they define which Biots still hold capacity.
- `Operations` owns operation queries.
- `Operations.Completion` provides pure completion evidence. `:create` and `:update_environment` use one clause set for each desired state.
- `Reports` handles node-facing ingestion through `observation`, `access_applied`, `resolution`, and `node_observation`.
- `Queries.Biots.get/2` and `list/2` build owner and collaborator `BiotView` values. `Access.readable/2` supplies their single read rule. `PublicationView.visible/2` limits collaborator publications to their view grants.
- `Queries.Nodes.list/1` and `Queries.NodeView` build the node inventory with capacity counts, live connections, and latest orphan reports.
- `Queries.Deployment.get/1` returns the publication and SSH settings in `DeploymentView`.
- `Queries.BiotView`, `Queries.PublicationView`, and `Queries.OperationView` provide pure projections. `BiotView` includes the actor's `role` and the row's `direct_secret_exposure_possible` column. Creation sets that column to `false`.
- `Authorization` owns the `grants` and `role` types and the pure role and policy predicates.
- `NodeConnections` is a registry of current node connections written by the control link.
- `NodeWake` provides one PubSub topic per node, plus `spec_changed/2` and `subscribe/1`.

#### `Biot.Server.Publications`

`publish/3` allocates a random hostname for a new port or reactivates its retained
inactive row. A row has state `:active` or `:inactive`. Republish keeps the same
hostname. `unpublish/3` makes the row inactive and deletes that port's view grants.
`withdraw_all/2` deactivates every row and deletes every view grant during destroy.
`active?/3` and `active_for/1` are the only reads of active publication rows.
`discover/2` returns active URLs allowed by the actor's role. Each mutation returns a
`Policy.Applied` result when it changes records, or a `Policy.Unchanged` result
when the requested policy already exists. Both result structs carry the Biot ID,
access revision, and `enforcement`.

#### `Biot.Server.Access`

`readable/2` builds one composable query. It is the only definition of which Biots
an actor may read. Owners, shell-grant holders, and view-grant holders match it.
`fetch_readable/2` returns the Biot and the actor's role, or `not_found` or
`forbidden`. `grants_for/2` is total over the requested IDs and returns an entry
for each one. `revoke_shell_grants/2` removes all shell grants during destroy.

`grant_shell/3` and `revoke_shell/3` manage Biot shell grants.
`grant_view/4` and `revoke_view/4` manage a principal's access to one published
port. `get_grants/2` returns the owner and explicit grants for the Biot. Mutation
results use `Policy.Applied` or `Policy.Unchanged`, with the same `enforcement`
field. Grants require known principals; view grants require an active publication
for the same Biot and port.

#### `Biot.Server.Policy`

`Policy.Applied` and `Policy.Unchanged` are the two successful policy results.
`Policy.enforcement()` is `:applied` or `{:pending, node_id}`.
`Policy.Transaction` owns the immediate transaction around each mutation. It
loads the Biot, authorizes the actor, checks that the Biot is not destroyed,
executes the callback's writes, bumps the access revision on withdrawal, wakes
the node after a withdrawal, reads enforcement from `AccessObservation` and
live connection state, and builds the result.

Policy callbacks receive the transaction's repository and Biot. They return
`:unchanged`, `{:added, multi}`, or `{:withdrawn, multi}`. Additions keep the
current revision and do not wake the node. Withdrawals add one revision and wake
the assigned node.

`Schema.AccessObservation` stores the latest access revision accepted by a node
connection. `Policy.Enforcement.access/3` reads that row and the live connection.
It reports `:applied` only for the current connection when the row has caught up
to the Biot's access revision. Otherwise it reports `{:pending, node_id}`.
`Policy.Enforcement` supplies this result to policy commands and `Queries.BiotView`.

#### Hostnames and projections

`Publications.Hostname.allocate/0` encodes 128 random bits as lowercase,
unpadded base32 and parses the label as a protocol hostname. The publication row
keeps that label while inactive. `publication_domain` reads
`BIOT_SERVER_PUBLICATION_DOMAIN`. `Queries.PublicationView` owns the URL format:
`https://<hostname>.<domain>`.

`Queries.PublicationView` sorts publications by port and projects each row into
its port and HTTPS URL. `Queries.AccessView` projects loaded shell and view rows
into the owner ID, sorted shell principal IDs, and sorted `{port, principal_id}`
view grants. `Queries.BiotView` uses `Policy.Enforcement` for the access status
shown with the rest of the Biot view.

`Authorization.role/3` returns `:owner` or `{:collaborator, grants}`. Its policy
predicates keep lifecycle, policy, and grant reads owner-only. `Access.readable/2`
owns Biot read access instead of a predicate in `Authorization`.

These modules follow the model contract. Additions never move the access
revision. Unpublish deletes the port's view grants in the same transaction.
Destroy deactivates publications and removes shell and view grants in one
transaction.

### Control protocol

- `Control.Listener` accepts mutually authenticated TLS node connections.
- `Control.Connection` owns one process per node connection.
  It handles hello, snapshot synchronization, ready, wake, desired sweeps, reports,
  heartbeats, diagnostics, and runtime-log requests.
  It sends `registration_abandoned` when an abandoned node attempts a connection.
  It sends one snapshot from one `Synchronization.specs/1` list as `SynchronizeBegin`,
  `SynchronizeItem` messages, and `SynchronizeEnd`. The connection schedules its first
  sweep one `desired_sweep_interval_ms` after ready and reschedules after each sweep.
  Wakes during synchronization are dropped because the next sweep repeats the comparison.
- The server starts the Registry before `Nodes.Startup` and starts the listener after `Nodes.Startup`.
  The Registry enforces newest-wins connection replacement.
- `Control.Synchronization.behind/2` runs one query. It returns Biots whose desired
  revision or access revision this connection has not accepted. The sweep resends
  `desired` for those Biots.
- `Reports.observation/4` and `Reports.access_applied/4` require the assigned node
  and the current connection through `NodeConnections.current?/2`. Equal or lower
  access revisions return `{:ignored, :revision_ahead}`. Reports from another
  connection return `{:ignored, :stale_connection}`. The connection logs ignored
  reports at debug level.
- `AccessApplied` is accepted during synchronization because the node sends it
  before `synchronized`.
- `Biot.Server.RuntimeLogs.get/3` reads a Biot's bounded runtime log after `Access.fetch_readable/2`.
  Owners and shell collaborators may read it. View-only collaborators may not.
- `Biot.Server.Diagnostics.get/2` authorizes a diagnostic through its failed operation and
  retrieves the bounded node-held content.
- The server connection keeps diagnostics and runtime-log requests in one `pending_requests` map.
  Each request has a `{:request_timeout, id}` timer. Timeout removes the request and releases its caller.
  Disconnect cleanup cancels every timer and releases every pending caller.

### Node status and lifecycle

`Schema.Node` stores `abandoned` with the other node statuses.
The node migration check constraint allows `enabled`, `disabled`, `retired`, and `abandoned`.
`Nodes.Registration` accepts the same four status values.
`CommandError` includes `node_abandoned`.
`Message.Reject` includes `registration_abandoned`.
`Failure` uses stage `node` and code `node_abandoned` for abandonment.

`Biots` loads the assigned node during the lifecycle plan phase.
`start`, `stop`, and `update_environment` return `node_abandoned` on an abandoned node.
Those commands still work on a disabled node.
`create` returns `node_abandoned` for an abandoned node and `node_disabled` for a disabled node.
`destroy` on an abandoned node records a failed `Operation` and sends no wake.

### Migrations

Migrations live under `priv/repo/migrations`.
`20260908000500` creates `Schema.AccessObservation`, which stores the latest
access revision accepted for each Biot.
Raw SQL is used only for `biots` and `view_grants`.
SQLite needs their composite foreign keys inline.

### Tests

`test/support/data_case.ex` gives tests a sandboxed Repo.
`test/support/fixtures.ex` builds rows.
Integration tests hit the real SQLite test database.

Focused server evidence includes:

- `policy/enforcement_test.exs` proves current-connection checks and access
  enforcement for missing, stale, and caught-up access observations.
- `queries/publication_view_test.exs` proves role-based publication visibility,
  HTTPS URL projection, port sorting, and empty-list handling.
- `queries/access_view_test.exs` proves owner projection and deterministic shell
  and view grant ordering, including empty lists.
- `queries/biot_view_test.exs` proves role, exposure, current connection state,
  node status, and access enforcement in the product view.
- `queries/operation_view_test.exs` proves operation kinds and outcomes remain
  unchanged in the projection, including failures.
- `policy_records_test.exs` uses real SQLite transactions to prove policy
  idempotence, authorization, revision and wake behavior, destroyed checks,
  publication state, view-grant cleanup, and enforcement progress.
- `authorization_test.exs` proves owner, policy-change, grant-read, and role
  predicates.

Node enrollment and abandonment evidence includes:

- `test/nodes/status_test.exs` is new. It covers the complete status table.
- `nodes/registration_test.exs` covers all four registration status values.
- `nodes_test.exs`, `nodes/plan_test.exs`, `nodes/startup_test.exs`, and
  `control_protocol_integration_test.exs` cover reload, abandonment, peer replacement,
  and the reject reasons.
- `control_protocol_test.exs` and `failure_test.exs` cover the new `Reject` and
  `Failure` values.

Lifecycle, access, query, publication, and redelivery evidence includes:

- `authorization_test.exs` covers owner-only commands and the owner and collaborator roles.
- `biots/create_test.exs` covers running and stopped creation, capacity, fingerprints, exposure, and retries.
- `biots/creation_fingerprint_test.exs` covers the `:biot_creation_v2` fields and boundaries.
- `biots/lifecycle_test.exs` covers lifecycle transitions, destroy cleanup, and access revisions.
- `control_protocol_integration_test.exs` covers synchronization, interval sweeps, dropped wakes, reports, reconnects, heartbeats, and diagnostics.
- `nodes_test.exs` covers status reloads, abandoned nodes, access revisions, failed operations, and connection closure.
- `operations/completion_test.exs` covers completion for create and environment updates in each desired state.
- `policy_records_test.exs` covers random hostnames, inactive publication rows, republish behavior, and grant cleanup.
- `queries/biot_view_test.exs` covers roles, exposure markers, live connection state, and access enforcement.
- `queries/publication_view_test.exs` covers role-based visibility and URL projection.
- `access_readable_test.exs` property-tests the single owner, shell-grant, and view-grant read rule.
- `biots/capacity_test.exs` covers room and counts, including destroyed Biots waiting for release.
- `biots/create_command_test.exs` property-tests accepted initial states and the running default.
- `biots/spec_test.exs` covers node-facing specs, selected environments, and access revisions.
- `control/synchronization_behind_test.exs` covers connection-specific execution and access acceptance, plus cleanup exclusion.
- `control/synchronization_test.exs` covers the shared inclusion rule for desired state and observed data.
- `publications/hostname_test.exs` property-tests 128-bit lowercase unpadded base32 allocation.
- `queries/biots_test.exs` covers readable get and list results, roles, collaborator visibility, pagination, and operation selection.
- `queries/deployment_test.exs` covers authenticated deployment settings and runtime reads.
- `queries/node_view_test.exs` covers node facts, capacity, connection state, status, and orphan reports.
- `queries/nodes_test.exs` covers node listing, capacity counts, live connections, and orphan reports.

## `apps/biot_node`

The node owns host reconciliation and reports inspected state to the server.

### Node state and reconciliation

- `Biot.Node.NodeState` is the derived view for one Biot. It holds `data`, `resolutions`,
  `installation`, `container`, and `NodeState.prepared`. `NodeState.prepared` is a per-environment
  resource map keyed by environment ID.
- `Biot.Node.Host.inspect_state/2` returns the five host facts in `Host.Inspection`.
  The controller adds `pending_exit` and `failure`, then builds `NodeState`.
- `Biot.Node.Reconcile.next/3` takes an `ExecutionSpec`, a `NodeState`, and the current action.
  It returns `:settled`, `{:run, action}`, `:cancel_current`, `{:blocked, reason}`, or
  `{:failed, failure}`.
- `Reconcile.Data`, `Reconcile.Environment`, and `Reconcile.Execution` compose the decisions.
  Ordinary convergence runs data, environment, execution, then release.
  Destruction runs execution, release, then data.
- `BlockReason` has three values: `{:inspection, failure}`, `{:current_action, action}`, and
  `{:recorded_failure, failure}`. `Retry.classify/4` maps host outcomes to bounded failures and
  retry policies.
  `Retry.failure/2` builds failures found without an action.
- `Action.metadata/1` holds only an action's stage and `cancellable?` flag.
  The environment actions are `{:prepare, env, manifest, allocation}` and
  `{:release_environment, env, allocation}`; the allocation is already the resource both actions
  need. Release never runs while an action is in flight.
- `InspectionFailure` keeps an unreadable resource distinct from an absent one.

#### BiotController

`Biot.Node.BiotController` owns one Biot. It loads the current `LocalIntent` from
`Biot.Node.Journal`, inspects the host, reports the inspection, asks
`Reconcile.next/3` for one action, and runs that action in one linked effect task.
The controller records an attempt before it starts the action. It records an effect result only
when the effect started under the current desired revision.

The controller resumes saved backoff from `next_attempt_at` and clamps the wait to
`retry_backoff_max_ms`. A refused retry write leaves its keyed diagnostic in the journal index and
reloads the current intent. The controller also reloads after a refused write without a diagnostic.

The controller's `phase` makes its waiting state explicit:

```text
:idle
{:recovering, task}
{:recovery_blocked, wake}
{:running, effect}
{:cancelling, effect, wake}
{:backing_off, wake}
{:waiting, reason, wake}
{:settled, wake}
```

`recover/1` is the one entry to the worker check. `{:recovering, task}` is entered at startup and
again after cancellation or a killed effect; it calls `Host.recover/1`, which confirms that the
private worker is absent before inspection or reconciliation. `{:recovery_blocked, wake}` retries
when absence is unknown and logs the reason. After recovery, the controller reloads current intent
before converging, so a queued revision cannot be acted on as stale state. `:idle` waits for intent
or synchronization. `:running` has one host effect in flight. `:cancelling` waits for the
cancellation grace period before killing an effect that did not stop. `:backing_off` waits for an
automatic retry. `:waiting` retries an inspection block. `:settled` re-inspects on the observation
interval.

A destroyed Biot writes its final report to the journal, hands it to the outbox, and exits normally.
`Biot.Node.BiotController` uses `restart: :transient`. `init/1` ignores an intent with a stored
destruction report.

The controller and its effect task share a failure group. A task crash takes down
the controller, and the supervisor restarts it. Restart loads durable intent and
inspects owned resources before it asks reconciliation to issue any action.
The controller reports every inspection, including a settled one, so the server
can learn about a container that exits on its own. A new desired revision clears
its stale backoff, inspection, or settled wake and pending container exit.
It keeps a running effect and its cancellation wake until that effect stops.

#### Controllers

`Biot.Node.Controllers` supervises the controller set. Its `Registry` uses the
opaque `BiotId` as each controller's key, and its `DynamicSupervisor` runs one
`BiotController` per Biot. `Controllers.Starter` is a long-lived bootstrap
process. It starts a controller for every durable journal intent at boot and
retries a failed start with one bounded timer per Biot.

The public API is `intent_changed/1`, `synchronized/1`, and `container_exited/1`.
The first starts or pokes one controller and schedules a starter retry when it cannot start.
The second receives the complete synchronized Biot ID set, starts or pokes every announced
controller, and pokes controllers absent from that set so they stop.
`container_exited/1` wakes the controller for an owned container.
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

- `Allocation` records a Biot's UID/GID range, private data root, network, and initialization.
  `Allocation.initialization` is `:uninitialized` or `:complete`.
- A `data_state` of `{:present, allocation}` carries only the allocation.
  The completion marker file holds the Biot ID.
  `Host.DataInspection` marks data `:lost` when that ID belongs to another Biot or does not parse.
- `Installation` selects the prepared artifact used by an allocation.
  `Resolution` records one environment's manifest and snapshot path.
  `LocalIntent` stores the last accepted `BiotSpec` and any destruction report.
- `NodePrivatePath`, `NetworkId`, and `ArtifactId` are node-owned parsed values for private paths,
  networks, and artifacts.
- `Biot.Node.StorePath` parses one canonical path at or inside a Nix store object.
- `Biot.Node.EnvironmentBundle` parses the format 1 gate and its seven fields: `format`,
  `closure_root`, `rootfs`, `entrypoint`, `shell_entrypoint`, `environment_file`, and `config_root`.
  It returns `:invalid_format` for a malformed shape or path and `:unsupported_format` for another
  numeric format.

### Host layer

`Biot.Node.Host` is the plain inspection and effect boundary called by reconciliation.
`inspect_state/2` accepts a Biot ID and `Host.Context`, and returns `Host.Inspection` with five host
facts: `data`, `resolutions`, `installation`, `container`, and `prepared`. The controller owns
`pending_exit` and `failure`, and builds the `NodeState` that reconciliation consumes. `run/2`
returns `:ok | {:error, Host.Outcome.t()}` and dispatches totally over every `Biot.Node.Action`
variant. The pure core has no worker state: workers are never desired or adopted, and recovery is
an imperative precondition.

The effect modules own host resources:

- `Host.Allocation` creates or repairs an allocation, its network, checkout, mounts, private Nix
  root, scratch, and initialization marker. It grants and reclaims mapped ownership, removes data,
  and releases the allocation only after its worker is absent.
- `Host.Environment` resolves, prepares, installs, and releases environment resources. Every Nix
  command runs in `Host.Worker`; release confirms worker absence, removes the environment, collects
  the private store, and deletes the resolution record last.
- `Host.Container` starts and retires rootless Podman containers. `run_container` uses the bundle's
  physical `--rootfs`, `--read-only`, `/tmp` and `/run` tmpfs mounts, the five allocation mounts,
  and a read-only `/nix/store` mount. `Host.Network` creates, inspects, and removes named private
  networks.
- `Host.Worker` owns the disposable build worker. `run/4` cancels any existing worker, runs one
  phase command, and cancels again on every exit; `cancel/2` is destructive and confirms absence;
  `state/2` is the read-only inspection; and `probe/2` runs the startup sandbox check. A private
  claim keyed by `{:worker, biot_id}` or `:probe` gives workers and the probe the same lifecycle.
  `Host.Worker.Spec` is the one worker description: name, labels, UID/GID map, network, mounts,
  tmpfs, and command. `Host.Worker.Layout` owns every container-side path and phase capability.
  `{:fetch, env}` mounts that environment read-write, release build support read-only, the private
  store and scratch read-write, and `nix.conf` read-only. `{:build, env, staged}` mounts that
  environment read-write, only its staged store inputs read-only, and the common store, scratch,
  and configuration. `:collect` mounts all environments read-only plus the common mounts.
  Its worker environment sets `NIX_PATH` empty, `TMPDIR=/build`, and scratch `HOME` and
  `XDG_CACHE_HOME`. Its tmpfs set is `/tmp`, `/root`, `/var`, and `/nix/var`. The UID/GID map
  confines files to the allocation's range; the isolated network confines traffic to the Biot;
  `--read-only` confines writes to explicit mounts and tmpfs; `unmask=/proc/*` lets Nix create its
  nested sandbox; `SYS_ADMIN` lets that sandbox mount its namespace; `--rm` and log driver `none`
  keep the disposable worker from retaining a root or logs. The probe uses the same boundary with
  no allocation, no network, and a throwaway store.
- `Host.SourceStaging` owns trusted fetch, copying `nix/` and `agent/` support, running
  `nix/fetch.nix`, and reading the staged out-link. `pins.json` is the one output contract.
  `Host.StagedInputs` is its pure, strict value: build support, Nixpkgs, layers, store paths,
  hashes, and revisions. The staged out-link is the GC root for that complete input set.
- `Host.PrivateStore` owns `host_path/3`, which maps a logical `/nix/store` object into the Biot's
  physical store, and `object_at/3`, which follows an out-link through that mapping.
- `Host.Git` is the one hardened Git shape: HTTPS-only transport, disabled system and global
  configuration and credentials, no prompt or askpass, no submodule recursion, and an empty
  template. `Biot.Protocol.RepositorySource` enforces HTTPS before a repository reaches Git.

The two environment phases are deliberately separate. Trusted fetch stages moving refs and writes
`pins.json`; `Host.Environment.prepare/4` invokes `nix build` with `--pure-eval` through `--expr`
and `fetchTree` over the staged mounts, passing `{staged, system}` to `nix/build.nix`. Pure
`Host.StagedInputs` turns the fetch output into the manifest and the exact inputs the build may
see. Release order is confirm worker absence, remove the environment and roots, collect, then
delete the resolution record last.

Pure derivations keep host facts separate from effects:

- `Host.DataInspection` derives allocation data state from journal ownership and filesystem facts.
- `Host.EnvironmentInspection` derives resolution and installation states. `EnvironmentInspection.prepared/1`
  returns one resource entry per environment.
- `Host.ContainerInspection` parses Podman JSON into the owned container value.
- `Host.Outcome` maps expected effect failures and bounded command diagnostics to retry reasons.

Support modules provide the smaller boundaries:

- `Host.Command` runs one executable through `setsid` with a timeout and bounded stdout and stderr.
  Its process-group handshake and `Host.Command.Reaper` ensure commands stop when their caller dies.
  `run/5` returns bounded output and truncation flags; `open/5` returns a `Command.Stream` for a
  long-running command. `Host.Podman` adds the configured Podman module and recognizes absent resources.
- `Host.ContainerEvents` reads Podman's `events` stream through `Command.open/5`, closes and
  reopens it after `container_events_retry_ms`, and uses `Names.owner/1` for ownership.
- `Host.Paths` owns the node-private layout. Everything Nix owns is below the Biot: `store_root`,
  `store`, `scratch`, `build_support`, `environments`, `environment`, `staged`, `environment_root`,
  `runtime_mounts`, and `allocation_owned_directories`. It also owns `worker_nix_config` and
  `git_template`. `Host.PrivateStore` maps the logical store into the physical one; `Paths` no
  longer owns a generic `mounts/2` API.
- `Host.Names` derives worker and probe names, network names, and labels. Workers use one stable
  `biot-worker-<id>` name with `io.biot.biot-id`, `io.biot.role=worker`, and a phase label; the
  startup probe is `biot-worker-probe` with `io.biot.role=probe`. `Host.Network` creates isolated
  networks with Podman's `--opt isolate=true` option. `Host.FileSystem` provides tri-state
  inspection, atomic writes, and tree removal.
- `Host.Podman.grant/3` gives a tree to the mapped allocation user. `reclaim/2` uses `podman unshare`
  to restore node ownership and write permission before removal. `Host.Config` parses and validates
  operator settings, while `Host.Context` binds them to one Biot ID.
- `Host.Setup` creates the node layout, the empty Git template, and the worker `nix.conf`. That
  configuration contains operator substituters and trusted keys, `sandbox = true`,
  `sandbox-fallback = false`, and `require-sigs = true`. Its startup sandbox probe rejects a host
  without nested isolation rather than allowing Nix to build unsandboxed.

The step removes `Host.SourceResolver`, `nix/pin.nix`, node-wide environment storage, and the
host's former `/nix/store` runtime mount. Environment storage and the runtime store now belong to
the Biot's private allocation; the runtime still receives that private store read-only at
`/nix/store`.

`Host.Command.Reaper` monitors the command caller. It ends the whole process
group and removes the stderr file when the caller dies. Normal completion calls
`release/1`; cancellation calls `cancel/1` and ends the group immediately. The
handshake keeps the group unstarted until the reaper has registered it, so a
caller killed between the announcement and the go line cannot leave a command
running without an owner.

### Node journal

`Biot.Node.Repo` is the Ecto SQLite repository, and `Biot.Node.Journal` is the
node-local domain API. The journal schemas are
`Journal.Schema.Allocation`, `Installation`, `Resolution`, `LocalIntent`, `RetryState`, and
`Journal.Schema.Diagnostic`. `local_intents` has a `destruction_report` column, and `retry_states`
holds one retry row per Biot. `Journal.Ecto.ParsedValue` stores canonical parsed
values as strings. `Journal.Ecto.Manifest`, `Journal.Ecto.BiotSpec`, `Journal.Ecto.Attempts`,
`Journal.Ecto.Failure`, and `Journal.Ecto.ExecutionReport` store validated JSON values.
`Journal.Migrator` runs `priv/repo/migrations/20260909000100_create_node_journal.exs`.

Journal queries scope resolution and installation reads and writes by Biot ID,
then check environment ownership before cross-resource changes. Its ownership
transactions use SQLite immediate mode. SQLite foreign keys restrict allocation
deletion while an installation or resolution remains, and the journal also checks
that no such records remain before release. `next_uid_start/3` finds the first
unused configured range, while the unique `allocation_uid_start` index closes the
concurrent-insert race.

`Journal.put_intent/1` and `Journal.replace_intents/1` accept intent and drop a
superseded retry row in the same transaction. `replace_intents/1` also deletes
local intents and retry rows for Biots omitted from the snapshot. It returns the omitted Biot IDs.
That deletion stops the controller, leaving any allocation for orphan reporting.
`Journal.put_destruction_report/2` keeps the intent row as a receipt and removes
its retry row. A later `put_intent/1` keeps that report.

`RetryState` stores the target revision, attempts by lifecycle stage, failure, and
`next_attempt_at`. A retry row always describes the revision in its intent row.
`Journal.retry_state/1` reads the row. `record_attempt/3`, `record_failure/4`, and
`clear_failure/2` return `{:ok, state}` or `:superseded`.

`Biot.Node.DataRootLock` owns a long-lived `flock` port on the data-root lock file.
`application.ex` starts `Host.Command.Reaper` before host effects.
When host configuration exists, it then starts `DataRootLock`, `Host.Setup`,
`Repo`, journal migration, `Control.RequestSupervisor`, `RuntimeLogs`, `Controllers`,
`Host.ContainerEvents`, and finally the configured control connection. The lock exists before
setup or journal access, and the connection starts after the journal and controller tree are ready.
Without host configuration, the node starts neither controllers nor a control connection.

### Environment artifact

The Nix environment artifact turns one resolved manifest into an immutable
launch bundle. The schema accepts `biot.packages`, `biot.environment`,
`biot.files`, and `biot.services.<name>`. A service declares `command`,
`directory`, `environment`, and `restart`.

The types and defaults live in `nix/module.nix`. Its `assertions` option keeps
cross-field rules such as reserved environment names and safe relative paths
with the schema. Compatible module definitions merge; conflicting definitions
fail with their source locations.

`nix/agent.nix` builds the vendored Go agent with `buildGoModule` and no module download. `nix/build.nix`
reads manifest JSON and writes bundle JSON. It builds `rootfs`, `entrypoint`, `shell_entrypoint`, and
one environment file. `loadEnvironment` is the one secret-loading rule: it loads the bundle
environment, then entry-specific variables, then files under `/biot/secrets`. `cleanEnvironment` is
the one clean-environment rule.

Each program gets a restart wrapper with `restartAttemptLimit = 5`,
`restartBackoffInitialSeconds = 1`, `restartBackoffMaximumSeconds = 4`, and
`restartHealthyRunSeconds = 60`. It owns the `always`, `on-failure`, and `never` rules, resets the
attempt count after a healthy run, and exits 70 when it exhausts attempts. The reserved `biot-agent`
program always runs the agent with the two required flags. The final `bundle.json` has seven fields:
`format`, `closure_root`, `rootfs`, `entrypoint`, `shell_entrypoint`, `environment_file`, and
`config_root`.

`nix/module.nix` defines `biot.shell` and service `directory = { root, path }`, where `root` is
`checkout` or `service_data`. The reserved service name is `biot-agent`; `BIOT_CONFIG_ROOT`, `HOME`,
`PATH`, and `TERM` are reserved environment names. Compatible module definitions merge; conflicting
definitions fail with their source locations.

The entry point starts `supervisord`. The container uses the bundle's empty, read-only rootfs with
read-only `/nix/store`, writable `/biot/checkout`, `/biot/home`, `/biot/service-data`, and `/biot/run`,
read-only `/biot/secrets`, plus writable `/tmp` and `/run` tmpfs mounts. The no-base-image invariant
keeps executables in the Nix store and makes missing private mounts fail instead of creating temporary
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

`config/config.exs` supplies server request and node defaults. The request, capture, controller,
and diagnostic settings are:

| Key | Default | Production override |
| --- | ---: | --- |
| `node_request_timeout_ms` | `10_000` | `BIOT_NODE_REQUEST_TIMEOUT_MS` |
| `node_response_max_bytes` | `256_000` | `BIOT_NODE_RESPONSE_MAX_BYTES` |
| `runtime_log_max_bytes` | `1_048_576` | `BIOT_NODE_RUNTIME_LOG_MAX_BYTES` |
| `host_command_max_stderr_bytes` | `256_000` | `BIOT_NODE_HOST_COMMAND_MAX_STDERR_BYTES` |
| `mkfifo_executable` | `mkfifo` | `BIOT_NODE_MKFIFO` |
| `head_executable` | `head` | `BIOT_NODE_HEAD` |
| `cat_executable` | `cat` | `BIOT_NODE_CAT` |
| `sleep_executable` | `sleep` | `BIOT_NODE_SLEEP` |
| `retry_budget` | `5` | `BIOT_NODE_RETRY_BUDGET` |
| `retry_backoff_min_ms` | `2_000` | `BIOT_NODE_RETRY_BACKOFF_MIN_MS` |
| `retry_backoff_max_ms` | `300_000` | `BIOT_NODE_RETRY_BACKOFF_MAX_MS` |
| `observation_interval_ms` | `30_000` | `BIOT_NODE_OBSERVATION_INTERVAL_MS` |
| `inspection_retry_ms` | `15_000` | `BIOT_NODE_INSPECTION_RETRY_MS` |
| `cancel_grace_ms` | `10_000` | `BIOT_NODE_CANCEL_GRACE_MS` |
| `controller_start_retry_ms` | `5_000` | `BIOT_NODE_CONTROLLER_START_RETRY_MS` |
| `container_events_retry_ms` | `5_000` | `BIOT_NODE_CONTAINER_EVENTS_RETRY_MS` |
| `diagnostic_max_entries_per_biot` | `5` | `BIOT_NODE_DIAGNOSTIC_MAX_ENTRIES_PER_BIOT` |
| `diagnostic_max_entry_bytes` | `65_536` | `BIOT_NODE_DIAGNOSTIC_MAX_ENTRY_BYTES` |
| `max_staged_specs` | `1_000` | `BIOT_NODE_MAX_STAGED_SPECS` |
| `max_frame_bytes` | `1_000_000` | `BIOT_MAX_FRAME_BYTES` |
| `builder_image` | pinned digest | `BIOT_NODE_BUILDER_IMAGE` |
| `binary_cache_urls` | `https://cache.nixos.org` | `BIOT_NODE_BINARY_CACHE_URLS` |
| `binary_cache_keys` | cache.nixos.org key | `BIOT_NODE_BINARY_CACHE_KEYS` |
| `build_support_dir` | release support directory | `BIOT_NODE_BUILD_SUPPORT_DIR` |
| `worker_timeout_ms` | `3_600_000` | `BIOT_NODE_WORKER_TIMEOUT_MS` |

`max_frame_bytes` is read from application configuration only by the node
connection. `config/runtime.exs` also reads the data root, UID/GID range, executable, connection, heartbeat,
reconnect, Podman, and TLS settings. The node's build settings are `builder_image` (required to
include a digest), `binary_cache_urls`, `binary_cache_keys`, `build_support_dir`, and
`worker_timeout_ms`; the node no longer needs Nix installed. The removed settings are
`nix_executable`, `nix_instantiate_executable`, `nix_build_file`, and `nix_pin_file`. The numeric
`BIOT_NODE_*` overrides must be positive integers. `Host.Config.from_application!/0` requires
complete, valid host configuration before node effects use it.

### Diagnostics, runtime logs, and control

`Biot.Node.Diagnostic` is the pure pair `{text, truncated}`. `Host.Diagnostic.from_command/1`
selects stderr when it is non-empty. It selects stdout otherwise. It carries the selected stream's
truncation flag. `Biot.Node.Host.Outcome` carries the diagnostic for an effect result.
`Biot.Node.InspectionFailure` carries the diagnostic for an unreadable inspection.

`Biot.Node.Diagnostics` is a module of functions. `put/4` writes a file under
`Paths.diagnostic/2` and indexes it in the journal table `diagnostics`. The unique key is Biot,
revision, and stage. A journal-owned sequence orders retention, so the newest
`diagnostic_max_entries_per_biot` rows stay. A same-key write replaces both the row and file.
`fetch/2` reads only an indexed file and applies a read bound. `forget/1` removes every indexed
file for a Biot. The index is authoritative. Unlink failures are logged. `Config.from_application!/0`
is the host configuration precondition for these operations.

`Biot.Node.RuntimeLogs` is a Supervisor over a Registry and a DynamicSupervisor.
`Biot.Node.BiotController.observe/1` calls `attach/3` with the inspected container. One `Capture`
follows each running container with `podman logs --follow`. It copies output into
`Paths.runtime_log/2`. The capture stays bounded by `runtime_log_max_bytes`.
`Metadata` owns the JSON file with the incarnation ID and truncation flag. A restart re-attaches to
the same incarnation and marks the gap. A new incarnation empties the log.
`fetch/2` returns the incarnation, bounded output, and truncation flag. `forget/1` stops capture and
removes the log and metadata. Capture faults log a warning and never change lifecycle results.
`Host.Container` starts containers with `--log-driver k8s-file` and
`--log-opt max-size=<runtime_log_max_bytes>`.

`Biot.Node.Control.Outbox` coalesces reports in a shared table. It keys observations by
Biot, resolutions by environment, and the node observation as one node-wide entry. A single wakeup
marker prevents duplicate connection wakeups. The connection drains the outbox after it acknowledges
`synchronized` and whenever a report wakes it. `Control` sends observations, resolutions, and
orphaned allocation reports to the outbox.

`Biot.Node.Control.Connection` runs diagnostic and runtime-log reads under
`Biot.Node.Control.RequestSupervisor`. It stores each task in `pending_reads` with a deadline.
A timeout terminates the task. A disconnect cancels all pending reads before reconnecting.
A complete snapshot calls `Journal.replace_intents/1`, then calls `Diagnostics.forget/1` and
`RuntimeLogs.forget/1` for every returned omitted Biot ID.

`Control.Connection` owns the reconnecting mutually authenticated TLS client, synchronization,
heartbeats, and report delivery. It has one `:synchronizing` status with a `Staging` value.
`Control.Staging` is pure: `begin/3`, `add/2`, and `complete/2` accept a bounded snapshot and return
five reasons: `:snapshot_count_over_capacity`, `:staged_count_exceeded`, `:duplicate_biot_id`,
`:synchronize_connection_mismatch`, and `:synchronize_count_mismatch`. A desired message during
staging also closes the connection with `:desired_during_snapshot`. Any snapshot error clears
staging before reconnecting.

An individual desired message uses `Journal.put_intent/1`; a complete snapshot uses
`Journal.replace_intents/1`. The node sends `access_applied` after either durable write, then hands
controller starts to `Controllers` before it sends `synchronized`. After that acknowledgement, the
connection compares journal allocations with synchronized intents and puts orphan reports in the
outbox. The connection replays stored destruction reports when it becomes ready and after each
repeated `desired` message. The application starts this connection only after host configuration,
the journal, and the controller tree are ready. Linux is required for the node control path.

### Tests

`test/test_helper.exs` excludes `:linux` tests outside Linux and `:nix` tests when
`nix` is unavailable. The node tests cover host derivations, journal ownership,
real Linux effects, and the controller shell:

- `action_test.exs` covers action stages and cancellation rules.
- `controller_pure_test.exs` covers pure controller projections, retry rules, and `RetryState`.
- `diagnostics_integration_test.exs` covers journal-indexed files, source and read truncation, replacement, retention, missing files, and logged unlink failures.
- `runtime_logs_metadata_integration_test.exs` covers metadata round trips and strict JSON validation.
- `host_command_ownership_test.exs` covers bounded stderr capture, overflow flags, FIFO drain cleanup, cancellation, and reaper ownership.
- `host_journal_integration_test.exs` covers diagnostic indexing, same-key replacement, retention order, omitted Biot IDs, retry rows, intent replacement, and destruction reports.
- `host_linux_integration_test.exs` covers Podman log-driver bounds and stream cleanup with real Linux commands.
- `host_pure_test.exs` covers diagnostic selection, data markers, per-environment prepared resources, strict staged-input parsing, private-store mapping, exact worker layouts, Git hardening, owner labels, and retry map types.
- `node_values_test.exs` covers node-owned parsed values, including `NetworkId`.
- `reconcile_important_cases_test.exs` covers unknown desired and sibling environments.
- `reconcile_invariants_test.exs` covers `Reconcile.next/3` result shapes and safety invariants.
- `reconcile_release_test.exs` covers release eligibility and ordering.
- `reconcile_sequences_test.exs` covers running, stopped, and destroyed convergence sequences.
- `support/reconcile_fixtures.ex` defines diagnostic-bearing inspection failures and current state shapes; `support/reconcile_generators.ex` defines property generators.

The Go tests cover `protocol/request_test.go`, `protocol/frame_test.go`,
`shellsession/session_test.go`, and `cmd/biot-agent/main_test.go`. They include fuzz targets for
requests, frames, and frame round trips, plus real Unix-socket, TCP-relay, and PTY tests.

The node tests cover the rewritten pure and Linux suites. The protocol suite property-tests
HTTPS-only `RepositorySource` parsing. `host_linux_integration_test.exs` covers real worker
cancellation, Podman inspection, mounts, rootfs, ownership, private-store use, and environment
release; its stateful environment fixture is skipped because the worker has no operator CA trust
for its self-signed test Git server until step 18. The two server proof scripts are skipped while
that large stateful evidence is replaced by bounded per-contract tests. The strict staged-input
parser test remains red for the production gap it exposes: extra keys and invalid NAR hashes are
not yet rejected. The evidence driver still covers worker isolation, hostile reads, cache use,
recovery, release, and startup sandboxing.

`docker/linux-host/run-tests.sh` runs `go test ./...` in `agent/` before the full Mix test suite
inside the Linux host image.

## Releases

The root Mix project defines two releases.
The `server` release includes `biot_protocol`, `biot_server`, and `biot_web`.
The `node` release includes `biot_protocol` and `biot_node`.

Build them with `MIX_ENV=prod mix release server` and `MIX_ENV=prod mix release node`.

## Tooling

`docker/linux-host/Dockerfile` includes `nftables` for rootless named Podman
networks and uses `usermod` to assign subordinate user and group IDs.
`/result` and `/result-*` are ignored.

`.mise.toml` pins Erlang 28.5 and Elixir 1.20.4 with OTP 28. The Linux host image includes Go
1.26.4, and the image tests use that toolchain.
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
`config/runtime.exs` also reads node data-root, UID-range, command, Podman, and control settings
for the production node release.

Server configuration includes `publication_domain`, `ssh_advertised_host`,
integer `ssh_port`, and `desired_sweep_interval_ms`. Production reads them from
`BIOT_SERVER_PUBLICATION_DOMAIN`, `BIOT_SSH_ADVERTISED_HOST`, `BIOT_SSH_PORT`,
and `BIOT_DESIRED_SWEEP_INTERVAL_MS`. No `BIOT_SERVER_PUBLICATION_HMAC_KEY`
setting remains.

## Host tests in Docker

Build the Linux host image, then run host tests with privileged access:

```sh
docker build -t biot-linux-host docker/linux-host
docker run --privileged --rm -it biot-linux-host
```

Run the full suite on Linux with `docker/linux-host/run-tests.sh` from the repository root.
