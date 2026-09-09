# Biot implementation model

This is the working implementation contract for [Biot](../README.md), building
on `README.md`. It defines the smallest model needed for the initial
system. Implementation details should remain local until a real failure or a
second implementation makes a broader abstraction useful.

The foundation is one server, a few fixed-assignment nodes, persistent working
data, and replaceable execution. Elixir/OTP implements the server and node as
separate releases, Phoenix the HTTP API and LiveView UI, Go the CLI, and Nix
environment composition. There is no scheduler, migration, ownership transfer,
or independent node authorization policy.

Elixir-shaped signatures describe application boundaries. Record notation lists
semantic fields, omitting routine timestamps and storage encodings. These are
contracts, not a requirement for one module, process, or table per value.

The first create-to-running slice validates the records and decisions in
sections 2–4, the lifecycle subset of the control protocol in section 6, and the
artifact boundary in section 7. Managed access and its protocol extensions state
required security semantics but remain provisional until their first adapters
are implemented.

### Show me the system

```text
                             server
                  ┌─────────────────────────┐
request ─────────▶│ Biot + Desired          │
                  │ Environment + Operation │
                  │ access policy           │
                  └────────────┬────────────┘
                               │ BiotSpec
                               ▼
                              node
                  ┌─────────────────────────┐
                  │ LocalIntent             │
                  │ BiotController          │
                  │ inspect → decide → act  │
                  └────────────┬────────────┘
                               │
                               ▼
                  allocation → working data
                               │
                  resolution → artifact
                               │
                  installation → container

                  Observation flows node ──▶ server
```

The server owns what should exist. The node owns host resources and reports what
does exist. BiotController derives one `NodeState` and performs one
reconciliation action at a time. Working data belongs to the stable allocation;
environments and containers are replaceable.

## 1. Concepts, guarantees, and boundaries

A biot is a stable identity with independently owned working data. An environment
describes frozen software inputs. An installation makes a built environment
available to one biot. A container runs that installation against the data.

| Term | Meaning | Authority |
| --- | --- | --- |
| Biot | Identity, owner, assigned node, and desired execution | Server database |
| Working data | Checkout, home, and persistent service data | Assigned node filesystem |
| Environment | Selected inputs and their frozen resolution | Server owns selection; assigned node owns resolution bytes and reports the manifest |
| Installation | Environment selected for execution against a biot's data | Node ownership metadata and inspected resources |
| Container | One replaceable execution | Podman, inspected by the node |
| Operation | Durable outcome of accepted asynchronous lifecycle work | Server database |
| BiotController | Disposable process serializing one biot's changes | Node process state |
| Managed session | One admitted stream with an owned lifetime | Session owner and current node connection |

The biot is also a shared trust boundary. A shell collaborator can change its
future behavior and use its credential grants. Revocation cannot undo either. A
view grant permits interaction with the published application; it does not make
that application read-only. Replacement changes execution, not arbitrary
persistent state.

The implementation preserves these invariants:

| Requirement | Enforcement |
| --- | --- |
| Accepted intent survives lost replies and process restarts | Server transaction commits desired state and an operation; synchronization reloads it |
| Initialized data are never silently replaced | Node ownership metadata and inspection distinguish uninitialized, absent, present, and unknown |
| At most one container uses a biot's writable data | One BiotController serializes changes; replacement inspects absence before start |
| Failed or obsolete preparation cannot replace current execution | Build completes before installation; BiotController rereads current desired state before installation or start |
| Destruction is terminal | Server retains the destroyed biot identity; node acknowledges only inspected resource absence |
| Managed access follows server policy and is withdrawable | Every admission checks current policy; owned sessions close after relevant committed changes or control loss |
| Process restart does not require remembered process state | BiotController begins with host inspection and converges from durable intent and ownership metadata |

| Boundary | Owns | Callers do not know |
| --- | --- | --- |
| Server application modules | Current authorization, transaction meaning, accepted result | SQL layout or node mailboxes |
| Server queries | Product meaning of intent, observation, and progress | Table joins and report encoding |
| Session owners and registry | Admission, stream lifetime, and matching closure | Transport-specific process layout |
| `Biot.Node.Reconcile` | Next action from an execution spec and inspected state | Podman, filesystem, Nix, or messaging commands |
| Node host implementation | Parsed inspection and retry-safe resource effects | Callers' domain policy |
| Environment implementation | Nix resolution, build, retention, and launch bundle | Lifecycle and presentation code |
| Container session implementation | PTY/exec, bytes, resize, exit, and closure | User policy and server records |

These are responsibility boundaries. Begin with concrete modules. Introduce a
behaviour or split a module only when another real implementation or separately
owned resource requires it. Tests use real temporary resources rather than
expectation-based mocks.

## 2. Server records and transitions

### Show me the server state

```text
Principal ──owns──▶ Biot ──selects──▶ Environment
                    │  │
                    │  ├──records───▶ Operation
                    │  ├──reports───▶ Observation
                    │  ├──grants────▶ ShellGrant
                    │  └──publishes─▶ Publication ──grants──▶ ViewGrant
                    │
                    └──assigned to──▶ Node ──reports──▶ NodeObservation
```

`Desired` is current intent inside the Biot. Operations preserve the history of
accepted lifecycle work; Observation holds the assigned node's latest report.
Policy records change synchronously and are not lifecycle Operations.

```text
Principal
  id: PrincipalId
  issuer: string
  subject: string
  last_seen_email: string | none
  last_seen_name: string | none

Node
  id: NodeId
  registration: RegistrationId
  status: enabled | disabled | retired
  platform: Platform
  max_biots: positive_integer

Biot
  id: BiotId
  name: BiotName
  owner_id: PrincipalId
  node_id: NodeId
  repository: RepositorySource
  creation_fingerprint: Digest
  desired: Desired
  access_revision: positive_integer

Desired
  revision: positive_integer
  state: running | stopped | destroyed
  environment_id: EnvironmentId

Environment
  id: EnvironmentId
  biot_id: BiotId
  selection: EnvironmentSelection
  resolution: unresolved | resolved(Manifest)

EnvironmentSelection
  base_nixpkgs: SourceSelector
  layers: list(SourceSelector)
  project_context: none | RelativeDirectory

Manifest
  base_nixpkgs: PinnedSource
  layers: list(PinnedSource)
  project_snapshot: none | {snapshot_id, digest}
  digest: Digest

Publication
  biot_id: BiotId
  port: Port
  hostname: Hostname

ShellGrant
  biot_id: BiotId
  principal_id: PrincipalId

ViewGrant
  biot_id: BiotId
  port: Port
  principal_id: PrincipalId

Operation
  id: OperationId
  actor_id: PrincipalId
  biot_id: BiotId
  kind: create | start | stop | update_environment | destroy
  target_revision: positive_integer
  outcome: pending | working | succeeded | failed(Failure) | superseded

Observation
  biot_id: BiotId
  connection_id: ConnectionId
  received_at: Timestamp
  accepted_revision: positive_integer
  installed_environment_id: EnvironmentId | none
  container: unknown | absent | present(IncarnationId, ContainerState)
  data: no_allocation | unknown | uninitialized | present | lost
  failure: none | {target_revision, Failure}
  applied_access_revision: positive_integer

NodeObservation
  node_id: NodeId
  connection_id: ConnectionId
  received_at: Timestamp
  orphaned_allocations: list({biot_id: BiotId, uid_range: {start, count}})
```

Principal identity is unique on issuer and subject. Email is a last-seen lookup
aid; grants attach only to a resolved principal. The creator owns the biot and
implicitly has shell and view access. Only the owner controls lifecycle and
sharing.

`BiotId` is a UUIDv4 accepted only in its canonical form.
`RepositorySource`, `SourceSelector`, `PinnedSource`, `Hostname`, `Port`, and
`RelativeDirectory` are parsed boundary values. Repository and source URLs
contain no embedded credentials. Relative directories cannot escape their
checkout context. `Platform` is a supported Nix host system supplied by the
assigned node; callers cannot select a different platform.

A publication row means the port is published. Its hostname label is the
lowercase, unpadded base32 encoding of the first 128 bits of HMAC-SHA-256 over a
version tag, the UUID bytes, and the port as an unsigned 16-bit integer, using a
server-held deployment key. The server stores that result on the row under a
uniqueness constraint, providing reverse routing and collision detection without
exposing the caller-generated ID. Recreating a publication derives the same
hostname. A uniqueness collision returns `hostname_conflict`; it never routes to
the existing publication. See [Stable URLs are derived rather than
allocated](#stable-urls-are-derived-rather-than-allocated) for the persistence
tradeoff.

`ArtifactId`, `MarkerId`, `ConnectionId`, `IncarnationId`, and
`PrivateDiagnosticId` are opaque identifiers minted by their owning boundary.
`NodePrivatePath` is a parsed path under the configured node data root and never
comes from an API caller. `ContainerState` is `running | exited(exit_status)`.
`Digest` is SHA-256 over a named canonical encoding. `Timestamp` is
server-recorded UTC display data, not an ordering authority.

Node status is one value, avoiding invalid combinations of enabled and retired
flags. Retirement is irreversible for a registration. Disabled nodes reject new
biots and managed access but may still have running containers.

Retirement is rejected while any assigned Biot's allocation is not known absent.
A permanently unreachable node therefore remains disabled initially. A future
operator abandonment action must record that data may remain; it must not report
unobserved cleanup as successful destruction.

### Operator enrollment

Nodes are enrolled through operator configuration read at server startup. The
operator generates stable opaque Node and Registration IDs and provisions each
node's private key and certificate using operator-managed tooling. Server
configuration binds the registration to that Node ID and authenticated peer
identity, supplies `max_biots` and the requested status, and configures trusted
server identity on the node. A registration ID alone is not a credential. The
node reports its platform in the handshake, before becoming ready.

Startup imports new registrations and applies status changes in one database
transaction before accepting connections. Repeated configuration is unchanged;
omitted non-retired registrations become disabled, never deleted; omitted retired
registrations stay retired. Disabling applies the access-revision changes in
section 5. Retirement checks the allocation
precondition above; an invalid transition rejects startup configuration. Retired
registrations remain tombstones and cannot be enabled again. Existing Node IDs
cannot be rebound to a different registration or peer identity initially.

Only the deployment operator can change this configuration; OIDC users have no
node administration API. Certificate issuance commands and protected key-file
layout belong to deployment implementation. See [Node administration is operator
configuration](#node-administration-is-operator-configuration) for the tradeoff.

Separate records hold browser and CLI credentials, SSH public keys, concrete
credential grants, and direct-secret delivery history. Secret bytes belong only
to protected delivery storage and never appear in operations, Nix values, or
logs.

Any authenticated principal may resolve a known email address. This intentionally
reveals membership within the one-provider, trusted-group deployment; it is not a
public user-discovery endpoint.

Use foreign keys and database uniqueness for facts the database can enforce:

```sql
CREATE UNIQUE INDEX principal_identity ON principals (issuer, subject);
CREATE UNIQUE INDEX live_biot_name ON biots (owner_id, name)
  WHERE desired_state <> 'destroyed';
CREATE UNIQUE INDEX publication_port ON publications (biot_id, port);
CREATE UNIQUE INDEX publication_host ON publications (hostname);
CREATE UNIQUE INDEX shell_grant ON shell_grants (biot_id, principal_id);
CREATE UNIQUE INDEX view_grant ON view_grants (biot_id, port, principal_id);
CREATE UNIQUE INDEX operation_revision ON operations (biot_id, target_revision);
CREATE UNIQUE INDEX environment_owner ON environments (id, biot_id);
```

`view_grants` has a composite foreign key from `(biot_id, port)` to
`publications(biot_id, port)` with `ON DELETE CASCADE`. The publication uniqueness
constraint is therefore also the referenced resource identity.

The Biot's `(desired_environment_id, id)` has a composite foreign key to
`environments(id, biot_id)`, so desired execution cannot select a sibling's
Environment. This constraint is deferred until commit: creation inserts the
Biot and its initial Environment in one transaction, with the Environment's
`biot_id` also referencing the Biot.

Retain the Biot row after destruction. Its stable ID is the creation retry key
and prevents resurrection or accidental reuse. `creation_fingerprint` is a
secret-free digest of the canonical creation request; it lets a retry return the
same Biot without retaining a general request ledger. Database transactions
establish authorization, capacity, uniqueness, desired revision, and operation
creation together.

`Manifest.digest` covers the canonical encoding of its other fields. A second
resolution report for the same Environment must have the same digest.

### Desired execution

```text
               start
  stopped ───────────────▶ running
     ▲                       │
     └──────── stop ─────────┘

  stopped/running ── update environment ──▶ same state, new revision
  stopped/running ── destroy ─────────────▶ destroyed (terminal)
```

The user-visible states are deliberately small. Rebuild is an environment
change; restart is stop followed by start after stop completes.

```elixir
@spec transition(Desired.t(), ExecutionChange.t()) ::
        {:changed, Desired.t()} | :unchanged | {:error, :destroyed}
```

`ExecutionChange` is `:start | :stop |
{:update_environment, EnvironmentId.t()} | :destroy`. Expected-revision checking
belongs to the application transaction before this pure function.

| Change | Result |
| --- | --- |
| Start | Set running and increment revision if currently stopped |
| Stop | Set stopped and increment revision if currently running |
| Update environment | Select a new Environment ID and increment revision |
| Destroy | Set destroyed and increment once |
| Any change after destroy | Reject; repeated destroy is unchanged |

Start and stop do not rebuild installed software. A completed stop guarantees
container absence, so a subsequent start creates a new container. Rebuild creates
a new Environment with the requested selection. There is no initial transition
that both retires and recreates a container atomically.

## 3. Application and query contract

Presentation code calls ordinary application modules, not server processes:

```elixir
Biots.create(actor, biot_id, %Create{})
Biots.start(actor, biot_id, expected_revision)
Biots.stop(actor, biot_id, expected_revision)
Biots.update_environment(actor, biot_id, %SelectEnvironment{}, expected_revision)
Biots.destroy(actor, biot_id)

Publications.publish(actor, biot_id, port)
Publications.unpublish(actor, biot_id, port)
Publications.discover(actor, biot_id)

Access.grant_shell(actor, biot_id, principal_id)
Access.revoke_shell(actor, biot_id, principal_id)
Access.grant_view(actor, biot_id, port, principal_id)
Access.revoke_view(actor, biot_id, port, principal_id)
Access.get_grants(actor, biot_id)

Biots.get(actor, biot_id)
Biots.list(actor, page)
Operations.get(actor, operation_id)
Diagnostics.get(actor, diagnostic_ref)
Principals.resolve_email(actor, email)
```

```text
LifecycleResult =
  ok(Accepted {operation_id, biot_id, revision})
  | ok(Unchanged {biot_id, revision})
  | error(CommandError)

PolicyResult =
  ok(Applied {biot_id, access_revision, enforcement: AccessEnforcement})
  | ok(Unchanged {biot_id, access_revision, enforcement: AccessEnforcement})
  | error(CommandError)

AccessEnforcement = applied | pending(NodeId)

CommandError =
  unauthenticated | not_found | forbidden
  | invalid_input(field_errors)
  | revision_conflict(current_revision)
  | destroyed
  | creation_conflict | name_conflict | hostname_conflict
  | node_disabled | capacity_exceeded
  | temporarily_unavailable

Failure =
  {stage, code, retry: automatic | after_change | operator,
   message, diagnostic_ref: none | PrivateDiagnosticId}
```

A lifecycle change other than destroy against a destroyed Biot returns
`destroyed`; the Biot remains readable.

The node retains a bounded diagnostic log for the latest failed attempt of each
Biot revision and returns its `PrivateDiagnosticId` with the Failure. The actor
who initiated the Operation or the Biot owner may fetch it through
`Diagnostics.get`; the server retrieves it from the assigned node on demand.
`Diagnostics.get` returns `ok({content, truncated}) | error(CommandError)`.
An unavailable node or an expired fetch deadline returns
`temporarily_unavailable`; a missing or expired diagnostic returns `not_found`.
The server enforces a finite configured deadline and byte limit, also sent with
the request so the node can bound its response. It releases pending request
state on timeout or disconnect and ignores late replies. A bounded log excerpt
indicates truncation. Exact limits, redaction, and local retention counts belong
to implementation, but the latest current-revision failure must remain useful
enough to diagnose.

Create and lifecycle changes return `LifecycleResult`; changed intent is
asynchronous and creates an Operation. Publication and grant changes return
`PolicyResult` and commit synchronously. A withdrawal increments the Biot's
access revision; its remote closure progress is reported through that revision
rather than an Operation per stream. An addition returns the current revision,
creates no new remote work, and returns the existing enforcement state, which
may still be pending from an earlier withdrawal. `Unchanged` describes intent or
policy, not runtime health.

A lost lifecycle response is handled by loading the Biot and its current
operation. Repeating a mutation with an old expected revision returns a conflict;
the client reloads instead of asking the server to replay a receipt. Repeating
creation with the same caller-supplied Biot ID returns the existing matching
Biot; a different creation body for that ID is a conflict.

Creation illustrates the application/effect cut:

```text
Biots.create(actor, biot_id, command):
  transaction:
    require current authenticated actor
    if biot_id exists:
      return it only when actor and creation fingerprint match
    resolve configured default node, if requested
    require enabled node and available assigned-biot capacity
    require available owner/name
    insert Biot with Desired(revision=1, running, environment), access_revision=1
    insert Environment owned by that Biot
    insert pending create Operation targeting revision 1
  after commit, best-effort wake the assigned node
```

Transactions acquire SQLite write ownership before dependent read/decide/write
work. They do not call nodes or execute builds. Pure functions own stable domain
decisions such as desired transitions, authorization, affected access scope,
status projection, and retry classification. Rules whose truth depends on current
database state remain transaction code and receive real SQLite integration tests;
do not duplicate database constraints in a speculative pure write-plan layer.

Committing a new desired revision marks every pending or working Operation with a
lower target revision superseded. Its host work may still settle, but it cannot
activate without another decision against current desired state. BiotView shows
the newest nonterminal Operation, or the newest terminal Operation when none is
pending.

Every non-destroyed Biot counts against `max_biots`. A destroyed Biot continues
to count until its assigned node reports `data: no_allocation`; accepted cleanup
does not release capacity by itself.

Destroy intentionally takes no expected revision. It is terminal from every
live state and wins according to its transaction order. That transaction also
deletes the Biot's publications and explicit grants and increments its access
revision before lifecycle cleanup begins. Unpublishing deletes the matching view
grants, so republishing restores the URL but not previously shared access.

Node reports are authenticated to a current registration and checked against
assignment and desired revision. A stale report cannot complete newer work. An
operation's historical failure remains visible even if later work makes the Biot
healthy.

| Kind | Completion evidence |
| --- | --- |
| Create/start | Desired environment installed and a running container |
| Update environment | Desired environment installed; running container if requested |
| Stop | Container absent after inspection |
| Destroy | Container, data, and allocation absent after inspection |

### Queries

```text
BiotView
  id, name, owner_id, node_id
  desired: Desired
  actual:
    never_reported
    | {received_at, freshness: current | stale,
       installed_environment: EnvironmentId | none,
       container: unknown | absent | {incarnation_id, state},
       data: no_allocation | unknown | uninitialized | present | lost,
       failure: none | {target_revision, Failure}}
  node: connecting | ready | unavailable | disabled | retired
  operation: OperationView | none
  access: {revision, enforcement: applied | pending(NodeId)}
  publications: list({port, url})
  direct_secrets_ever_delivered: boolean

OperationView
  id, kind, target_revision, outcome

AccessView
  owner_id
  shell_grants: list(PrincipalId)
  view_grants: list({port, principal_id})
```

The server owns these projections. Observations are last reported facts, not a
promise of current liveness. Freshness is derived: an Observation is current only
while its connection ID is the node's current healthy connection; it is never a
stored flag. BiotView projects current failure from the latest Observation. A
matching nonterminal Operation may become failed, but a terminal Operation
remains historical even if the container later exits. The node retains the local
retry state needed to avoid repeating a deterministic failure.

HTTP routes are thin mappings to these operations. JSON uses string tags and
opaque IDs. Browser mutations require CSRF and exact-origin checks; API clients
use revocable bearer credentials. Accepted lifecycle changes return 202 with an
operation location. Creation is `PUT /biots/:id`, making the caller-generated ID
part of its retry semantics. Committed policy changes return 200 with their
access revision and current enforcement state. Expected-revision conflicts
return 409 and invite a reload.

## 4. Node state and reconciliation

### Show me node ownership

```text
Allocation
├── UID/GID range
├── network
├── checkout, home, and service data
└── Installation ───────────────┐
    └── Container               │ uses
                                ▼
Environment ──▶ Resolution ──▶ prepared artifact
```

Allocation owns the irreplaceable and exclusive resources. Environment owns the
replaceable software path. Installation is the handoff between them, and a
container may use only the allocation's current installation.

The server sends the node a complete execution input rather than requiring it to
join server records:

```text
BiotSpec
  execution: ExecutionSpec
  access_revision: positive_integer

ExecutionSpec
  biot_id: BiotId
  repository: RepositorySource
  desired: Desired
  environment:
    id: EnvironmentId
    selection: EnvironmentSelection
```

The execution spec contains server-owned intent. The node's own `Resolution`
record supplies its manifest and snapshot; sending that value back to its producer
would introduce another copy that could disagree. The access boundary consumes
`BiotSpec.access_revision`, while reconciliation consumes only `execution`.

The node persists only ownership facts that cannot be reconstructed safely from
arbitrary host resources:

```text
Allocation
  biot_id: BiotId
  uid_range: {start, count}
  data_root: NodePrivatePath
  network_id: NetworkId
  initialization: uninitialized | complete(MarkerId)

Installation
  biot_id: BiotId
  environment_id: EnvironmentId
  artifact_id: ArtifactId

Resolution
  environment_id: EnvironmentId
  manifest: Manifest
  snapshot_path: NodePrivatePath | none

LocalIntent
  biot_id: BiotId
  biot_spec: last accepted BiotSpec
```

The node builds one reconciliation view by joining that metadata with host
inspection:

```text
Resource(T) = unknown(InspectionFailure) | absent | present(T)
DataState =
  no_allocation
  | unknown(Allocation, InspectionFailure)
  | uninitialized(Allocation)
  | present(Allocation, MarkerId)
  | lost(Allocation)
InstallationState =
  none
  | unknown(Installation, InspectionFailure)
  | present(Installation)
  | lost(Installation)
ResolutionState =
  none
  | unknown(Resolution, InspectionFailure)
  | present(Resolution)
  | lost(Resolution)

NodeState
  data: DataState
  resolution: ResolutionState
  installation: InstallationState
  container: Resource({incarnation_id, allocation_id, environment_id, state})
  prepared: Resource(map(EnvironmentId, ArtifactId))
  failure: none | {target_revision, Failure}

CurrentAction = none | Action
```

Every `NodeState` belongs to one Biot. Its `prepared` map contains only that
Biot's Environments; reclamation never scans a sibling's artifacts. The host
checks that a release target belongs to the controller's Biot before removing
its owned root.

These derived states combine recorded ownership with inspection rather than
presenting journal and host copies to reconciliation separately. `unknown`,
`absent`, and `present` remain semantically distinct. Unknown blocks only actions
requiring that fact. A resource recorded as previously installed or initialized
but found absent is `lost`, not uninitialized. Ownership mismatch is an explicit
failure, never permission to adopt or delete an arbitrary resource.

Allocation metadata and initialization markers live outside writable mounts.
Initialization promotes staged data atomically and writes an owned completion
marker. If metadata says initialization completed and data are absent, the result
is visible lost-data failure, not another clone.

The node process takes an exclusive lock on its configured data root before
loading allocations. A second process cannot coordinate the same resources. A
released UID/GID range is not reusable until the prior allocation's container and
data root are both inspected absent.

Prepared artifacts are Nix roots or equivalently inspectable host resources;
there is no second journal copy of their semantic state. Installation is an
atomic selection owned by the allocation. Removing an installation releases its
root only after no current container or in-flight action needs it.

`environment_action` also owns eventual reclamation. A resolution snapshot and
prepared artifact remain retained while their Environment is desired, installed,
or used by the current action; resources outside those sets are releasable. A
missing installed artifact makes the Installation lost. A missing resolution
snapshot prevents preparing that Environment but does not invalidate an intact
installed artifact. The concrete rooting and collection schedule belongs to the
environment implementation.

### Pure decision core

```elixir
@spec next(ExecutionSpec.t(), NodeState.t(), CurrentAction.t(), ControlState.t()) ::
        :settled
        | {:run, Action.t()}
        | :cancel_current
        | {:blocked, BlockReason.t()}
        | {:failed, Failure.t()}
```

`ControlState` is `ready | offline`.

```text
BlockReason =
  inspection(InspectionFailure)
  | current_action(Action)
  | recorded_failure(Failure)
  | control_offline
```

```text
Action =
  allocate(biot_id)
  | initialize(allocation, repository)
  | resolve(environment_id, selection, allocation)
  | prepare(environment_id, manifest)
  | retire(incarnation_id)
  | install(allocation, artifact_id, environment_id)
  | start(allocation, installation)
  | release_environment(environment_id)
  | remove_data(allocation)
  | release_allocation(allocation)
```

```text
ExecutionSpec + NodeState
          │
          ▼
     data_action ──not ready──▶ one action/block/failure
          │ ready
          ▼
 environment_action ─────────▶ one action/block/failure
          │ ready
          ▼
   execution_action ─────────▶ one action/block/failure/settled
```

`next` composes three small pure decisions:

1. `data_action` establishes or removes owned allocation and initialized data.
2. `environment_action` resolves, prepares, installs, and releases environment
   resources.
3. `execution_action` retires or starts a container from the installed environment.

Destruction has priority and walks those resources in reverse ownership order.
For ordinary intent, data readiness precedes environment readiness, which
precedes execution. Each helper returns ready, an action, a block, or a failure;
the top-level function selects only one action.

Important cases are:

| Facts | Decision |
| --- | --- |
| Completed initialization; data absent | Fail lost data |
| Required inspection unknown | Block and retry; never infer absence |
| Environment unresolved | Resolve once into its atomic node location |
| Build fails with old container running | Report failure and preserve old execution |
| Desired environment differs from installation | Prepare, retire, inspect absence, install |
| Desired stopped | Retire execution; preparation may finish without starting |
| Desired destroyed | Cancel current task, retire, remove data, release allocation |
| Control offline | Finish an already accepted stop/destruction and inspection; do not install or start |
| Desired running; container exited | Retire it; after absence is observed, return an automatic-retry failure to the controller |
| Current revision has a recorded after-change/operator failure | Remain blocked; do not emit the same failure again |

The BiotController rereads the execution spec and inspected state after every
action. A preparation result carries no authority to install or start. Stop or
destruction cancels a long preparation so execution can retire promptly; a Nix
daemon computation may continue only if it cannot activate resources or access
private data.

Cancellation progress, retry timing, and retry budgets belong to BiotController,
not the pure core. While an action is cancelling or a retry is backing off, the
controller does not call `next`. An automatic failure schedules bounded backoff;
repeated container exits eventually become an operator failure that remains
until desired revision changes. Exact delays and attempt limits are operator
configuration chosen with the host implementation.

### Imperative shell and crash recovery

The concrete host implementation provides inspection, execution, and
cancellation. Do not introduce a behaviour solely to replace it with an
expectation-based mock.

```text
BiotController receives desired intent:
  persist the newer BiotSpec locally
  inspect owned resources
  ask Reconcile.next for one action

BiotController runs an action:
  launch it in one supervised, killable process group
  retain only ephemeral task ownership

BiotController receives completion or task death:
  inspect affected resources regardless of reported success
  update ownership metadata from inspected evidence
  reload the current BiotSpec
  reconcile again

BiotController restarts:
  terminate owned helper process groups
  ignore only detached Nix realization that cannot activate resources
  inspect before issuing any conflicting action
  reconcile from durable desired and allocation metadata
```

An effect may complete immediately before its task dies. Allocation, promotion,
installation, container creation, and deletion therefore have stable owned
identities and converge when repeated. Short-lived command completion is never
trusted over subsequent inspection. See [Host work converges rather than
executing exactly once](#host-work-converges-rather-than-executing-exactly-once).

Nix realization may outlive its caller inside the shared daemon. It is harmless
until the BiotController roots and installs its output. The build pool bounds
work during normal operation; after pool restart it may temporarily undercount
daemon work.

## 5. Managed access

This section fixes the authorization and lifetime invariants. Its adapter and
wire shapes are provisional until preview or shell access is implemented.

### Show me revocation

```mermaid
sequenceDiagram
    participant Owner
    participant Server
    participant Sessions as Session owners
    participant Node
    Owner->>Server: Withdraw access
    Note over Server: Commit revision r
    Server->>Sessions: Close all for Biot
    Server->>Node: BiotSpec(r)
    Server-->>Owner: Committed; enforcement pending
    Note over Node: Close all for Biot
    Node-->>Server: Observation(applied r)
```

The response does not wait for node application. This example returns pending;
if acknowledgement has already arrived, it may return applied instead.

The revision is the durable target. Session identities remain transient, and a
missed notification is recovered by comparing desired and observed revisions.

```elixir
Access.open_preview(auth_context, publication, preview_request)
Access.open_shell(auth_context, biot_id, shell_request)
```

Each returns a live owned handle or an admission error. The caller cannot use an
authorization result to open an untracked stream. Preview destinations are
resolved by the node from the current biot and port, never supplied as arbitrary
host addresses.

Admission follows this ordering:

```text
create and register a session owner in checking state
read current policy from SQLite
if the owner was closed or policy denies, stop
open the upstream through the current node connection
mark the owner admitted
if closure raced with opening, close the upstream immediately
```

Registration before the policy read matters. After a withdrawal commits, it
closes every registered owner for that Biot. An owner registered after that
enumeration necessarily reads the committed policy. An owner already registered
is found whether it is checking, opening, or admitted. Per-owner mailbox ordering
prevents a close received during checking from being forgotten. No global
admission coordinator or pre-transaction barrier is required.

Access changes use ordinary application transactions:

```text
withdraw access:
  authorize current owner and mutate the grant
  increment the affected biot's access revision
  commit
  close every local session owner for the biot
  deliver the new BiotSpec to its ready node
```

Revocation, unpublishing, destroy, and credential revocation use this path.
Stopping needs no access revision: retiring the container closes its sessions.
Granting access can commit without closing sessions or changing the revision.
Disabling a node increments the access revision of every assigned Biot in one
SQLite transaction, then closes the node connection. This broad write is
reasonable for the fixed small node capacity.

When a node receives a higher access revision, it closes every managed session
for that Biot before reporting the revision applied. It does not need remote
session IDs or policy scope. A disconnected node remains pending until
its old connection has exceeded the loss timeout or a new connection synchronizes
current policy before opening access. The UI reports that node as pending, not
individual historical streams.

Access revisions only increase. Nodes ignore a revision below the highest one
they have applied; acknowledging a higher revision also acknowledges every lower
withdrawal.

This intentionally favors a small recovery protocol over precise remote closure;
see [Policy progress is per assigned node](#policy-progress-is-per-assigned-node).

Committed withdrawal cannot depend on the request process surviving. On server
start, node reconnection, and a periodic sweep, the server compares each Biot's
access revision with its Observation and resends closure work while the assigned
node is behind. The sweep operates on revisions, not durable session records.

A server crash closes server-proxied sessions with their owners. Node-side
sessions close after control-link loss detection. This is the bound on revocation
during server failure. There is no promise to stop detached workload processes or
undo filesystem changes made through an earlier shell.

The same policy predicates authorize browser terminal and SSH access. Transport
adapters remain separate because their authentication and data paths differ.
Credential integrations reuse parsed grants and owned lifetimes only after a
concrete integration demonstrates that the same access shape fits.

## 6. Connection and transport boundaries

One mutually authenticated control connection exists per current node
registration. Its states are disconnected, synchronizing, and ready. A new
connection negotiates a protocol version before synchronization. The releases
reject a connection when they have no supported version in common.

```text
Node -> server:
  hello(registration_id, supported_protocol_versions, platform)

Server -> node:
  connected(connection_id, selected_protocol_version)
  | reject(unsupported_protocol_version)

Server -> node:
  synchronize(connection_id, biot_specs)
  desired(biot_spec)
  diagnostic(request_id, diagnostic_id, max_bytes, timeout_ms)

Node -> server:
  synchronized(connection_id)
  observation(biot_id, execution_report)
  resolution(environment_id, manifest)
  node_observation(orphaned_allocations)
  diagnostic_result(request_id, {content, truncated} | not_found)

Both:
  heartbeat(challenge) | heartbeat_response(challenge)
```

The selected version governs every later message on the connection. Codecs
reject messages and fields outside that version. Version negotiation is part of
the initial lifecycle protocol; rolling-upgrade compatibility is added only when
there are two released versions to support.

Synchronization delivers each access revision as part of BiotSpec. When managed
access is implemented, the node closes sessions from the old connection before
acknowledging synchronization, and every new node-side admission asks the server
for current authority. Define that admission's complete request/reply shape with
the adapter. Listener discovery likewise gets either an observation field or a
request pair when publishing is implemented, rather than specifying both
possibilities now.

After receiving the complete BiotSpec set, the node compares it with its local
allocations and reports those whose recorded Biot ID is absent from the set.
The server adds the current connection ID and receipt time and stores them in
NodeObservation. Initially the operator reads structured server logs: each report
logs node identity, connection, receipt time, and orphaned allocations, including
an empty list when resolved. Startup also logs stored reports as historical
observations. There is no initial NodeView or node query API. Orphans consume
local resources but are never automatically adopted or deleted.

The assigned node resolves an Environment atomically under its Environment ID.
It reports the resulting manifest; retry returns the same locally persisted
resolution. A different manifest for an already resolved ID is corruption. The
server stores the report but sends no canonical-resolution acknowledgement.

The connection is the sole ordered writer for node control messages. Access
extensions preserve that ordering: session owners register before open, and
unknown or closed session IDs cannot attach an independent data stream. Losing
control closes managed node access within a configured timeout; containers and
their background work may continue.

### Preview browser boundary

Preview applications are hostile sibling origins relative to the control plane.
The proxy removes Biot credentials and caller-supplied identity headers, inserts
verified identity headers, and prevents application responses from replacing
Biot authentication state.

Control and preview sessions are separate. Preview login handoff uses a
short-lived, single-use code bound to the exact host and browser challenge.
Cookies are host-only, Secure, HttpOnly `__Host-` cookies. Control mutations and
LiveView/WebSocket admission require CSRF and exact-origin checks. Preview
origins receive no credentialed control-API CORS access. These requirements are
part of the real threat model and are not deferred with admission barriers.

### Container sessions and SSH

Browser terminal and SSH adapters share the concrete container PTY/exec boundary,
not their outer protocol logic. A handle is bound to one incarnation and cannot
outlive its authorized owner. Every SSH channel on a reused connection checks
current authority. Unsupported forwarding and host filesystem subsystems are
disabled. Closing managed access ends the transport and foreground execution,
not arbitrary detached work.

### Credentials

Public cloning is the first implementation slice. A later private workflow must
name an explicit biot grant before a container exists. Real credentials stay in
node-controlled integration code and go only to the intended upstream. Returning
an upstream token to a generic workload helper does not count as mediation.

Git, API proxying, and signing do not initially share a transport abstraction.
Implement one useful workflow, test actual credential retention and interruption,
and extract only demonstrated common values such as parsed scope and lifetime.
Direct secret delivery remains a separate explicit feature whose historical
exposure cannot be revoked.

## 7. Environment artifact contract

Layers are Nix modules evaluated together with one pinned base package set and
the assigned node's platform. Use ordinary imports, typed options, defaults, and
source diagnostics rather than another merge language in Elixir.

Initial author-facing schema:

```nix
{ pkgs, ... }: {
  biot.packages = [ pkgs.git pkgs.nodejs pkgs.vim ];
  biot.environment.EDITOR = "vim";
  biot.files."example/settings".text = "mode = development";
  biot.services.web = {
    command = [ "${pkgs.nodejs}/bin/node" "server.js" ];
    directory = "checkout";
    environment.PORT = "3000";
    restart = "on-failure";
  };
}
```

Compatible definitions compose. Incompatible definitions fail with sources;
list order does not silently choose a winner. Nix generates an immutable launch
bundle for an existing service runner. It does not rewrite user-owned home data.

```text
EnvironmentBundle
  format: 1
  closure_root: StorePath
  entrypoint: StorePath
  environment_file: StorePath
  config_root: StorePath
```

All paths are parsed references within the retained closure. BiotController sees
only an Artifact ID; the environment and host implementation interpret the
bundle. The Nix store is mounted read-only, while checkout, home, and service
data are private writable mounts.

Inputs and outputs placed in the shared store must be safe for other biots on
that node to read. Evaluation and builds receive no node credentials or access to
other biots' private data. Confidential local-source realization is unsupported
until a real private workflow establishes a different storage boundary.

Adding a service option should change the Nix schema and generated runner
configuration without changing Desired, node messages, or reconciliation. Prove
the artifact and mount arrangement with one useful stateful environment before
expanding the schema.

## 8. Process ownership and operational limits

Do not freeze a complete supervision tree before implementation. Preserve these
ownership rules instead:

- One BiotController serializes each biot; blocking host work runs in supervised
  tasks.
- A BiotController and its current effect task share a failure group.
- Session owners monitor their requester and current control connection.
- Node connection state is reconstructed from durable registrations and current
  synchronization, not remembered process membership.
- Registries use opaque IDs rather than dynamically created atoms.
- Expected build and configuration failures are values, not crashes to restart.

The host enforces disjoint UID/GID ranges, private data and network namespaces,
read-only shared software, and destination ingress rules that also reject sibling
biots. Test actual traffic and mounts; flags alone are not evidence.

Operator configuration bounds containers, build concurrency, sessions, buffers,
assigned biots, logs, and scratch growth. Disk exhaustion is reported. There is
no fair-share scheduler, billing, capacity reservation, or tamper-evident audit
system.

In the first slice, disk exhaustion is a typed allocation, initialization, or
build failure with a diagnostic. Proactive disk-pressure health and alerting
belong to the operator's host monitoring until observed use establishes a useful
node-level product status.

Database loss and node storage loss are outside ordinary recovery. Surviving
files may be exported manually with coordination quiesced. Unknown resources are
not automatically adopted or deleted. Node retirement is not represented as disk
erasure.

## 9. Create-to-running walkthrough

The operator first provisions node credentials and matching server configuration,
starts the server to import the registration, and starts the node. Mutual
authentication, protocol negotiation, and synchronization establish a ready node
with a reported platform. The first slice then crosses each durable and effect
boundary once:

```text
CLI:
  generate canonical random Biot ID b_1
  PUT b_1 with repository and environment selection

Server transaction:
  validate actor, ID, capacity, name, and node
  insert Biot b_1 with Desired(revision=1, running, e_1)
  insert Environment e_1 owned by b_1
  insert pending create Operation op_1
  commit, return Accepted, and wake the node connection

Server connection:
  use the ready connection's negotiated protocol version
  send BiotSpec(ExecutionSpec(b_1, repository, Desired(1), e_1 selection),
                access_revision=1)

Node BiotController:
  persist the complete BiotSpec
  inspect and derive NodeState(no allocation)
  allocate UID range, data root, and network
  initialize the checkout once and inspect its completion marker
  resolve e_1 atomically and report its canonical Manifest
  prepare and retain its EnvironmentBundle
  install e_1 against b_1's allocation
  start container incarnation c_1
  inspect after each effect and report Observation(connection, revision=1)

Server report transaction:
  require the current registration, assignment, and report revision
  store the latest Observation
  mark op_1 succeeded when e_1 is installed and c_1 is running

Query:
  project BiotView from Desired, Observation, Node, and op_1
```

If an HTTP response or wakeup is lost, the Biot and Operation already exist and
synchronization redelivers the BiotSpec. If the node process dies, its replacement
loads that spec and allocation metadata, inspects resources, and
continues from the first unmet condition. It never restarts the sequence from
the clone step merely because process memory was lost.

## 10. Required evidence

Pure unit tests cover desired transitions, authorization, affected access scope,
the three reconciliation decisions, retry classification, and query projection.
Database and process rules use integration tests with real OTP trees, temporary
SQLite databases, real worker termination, and small protocol peers. Host tests
use temporary owned resources and the relevant real host facilities.

| Example | Evidence sought |
| --- | --- |
| Lost create response | Same caller-supplied Biot ID; one initialized checkout |
| Create followed by a newer desired revision | Older pending Operation becomes superseded |
| Pending destruction at node capacity | Capacity remains occupied until allocation absence is reported |
| Initialized data absent versus inspection unavailable | Lost-data failure versus blocked retry |
| Second node process on the same data root | Exclusive ownership fails before resource management starts |
| Allocation release and UID reuse | Range remains unavailable until container and data are inspected absent |
| Stop followed by start | Stop observes absence; start creates a new incarnation |
| Build finishes after stop or destroy | Artifact cannot independently install or start |
| BiotController dies around a host effect | Restart inspects before issuing conflicting work |
| Build fails while an old environment runs | Old container and working data remain intact |
| Nix evaluation or build fails | Authorized owner can retrieve a bounded useful diagnostic |
| Desired-running container repeatedly exits | Retries back off and eventually require owner action |
| Unsupported node protocol | Handshake rejects before synchronization |
| Startup enrollment and status changes | Configured peer authenticates; omission disables; retired identity cannot return |
| Cross-biot environment selection or artifact release | Database ownership constraint or host ownership check rejects it |
| Diagnostic fetch stalls or exceeds its limit | Caller completes within its deadline; response stays bounded |
| Server database omits a node allocation | NodeObservation exposes the orphan without adopting or deleting it |
| Admission races revocation | Registered owner is denied or subsequently closed |
| Revoke one user while another is connected | All node sessions close; still-authorized users reconnect |
| Server dies after withdrawal commit | Revision sweep eventually resends closure work |
| Node disconnects during revocation | Pending revision clears after timeout or synchronized reconnect |
| Server restarts with node SSH sessions | Sessions close within the documented control-loss bound |
| Unpublish and republish | Same hostname returns without old view grants |
| Preview sibling-origin requests | Application cannot acquire or replace control authority |
| Unpublished sibling listener | Destination ingress rejects actual traffic |
| Stateful composed service | Replacement preserves data and environment details stay out of BiotController |

## 11. Why the model stops here

Biot protects people from accidental cross-biot access, unauthorized use of its
managed entry points, hostile preview origins, and routine process or network
failure. It does not protect a biot from a determined shell collaborator, recover
lost node storage, or provide highly available control. The following choices
keep the initial design proportional to that boundary.

### Node administration is operator configuration

The operator provisions peer credentials and changes node enrollment and status
through startup configuration. Durable registration records preserve retirement
and assignment history; configuration omission disables a node. Orphan reports
are visible in structured operator logs.

This accepts a server restart for node administration and operator-managed
credential provisioning in exchange for avoiding an enrollment service and
administration API for a few nodes. Add online administration, credential
rotation, or a NodeView when operating the deployment demonstrates the need;
preserve the existing identity and retirement rules across that change.

### Revocation is bounded rather than transaction-linearizable

The server commits new policy, closes every registered session for the Biot, and waits
for its assigned node to apply the access revision. A stream may finish opening
concurrently and then be closed. SQLite transactions alone cannot order a later
network open against a policy write; session registration and ownership provide
the useful guarantee without a global admission coordinator.

This exchanges a very small opening interval for avoiding barriers, mutation
workers, per-session durable obligations, and a deployment-wide access failure
group. Add admission barriers only if a real race test demonstrates an
unacceptable interval that registration-before-check cannot bound. Add durable
per-session closure records only if product reporting must distinguish individual
transport acknowledgements from node policy application.

### Host work converges rather than executing exactly once

A BiotController crash kills its supervised process group, discards ephemeral task
ownership, and inspects before another action. The command may have completed
before its caller died, so effects use stable owned identities and tolerate
repetition.

This exchanges seamless continuation and exact accounting of external commands
for removal of durable Work records, work inspection protocols, cancellation
settlement, and build-pool reconstruction. Introduce durable external Work IDs
only for a demonstrated effect that cannot be killed, inspected, or safely
repeated. A Nix daemon build that continues harmlessly but temporarily consumes
capacity is not by itself such an effect.

### Reconciliation receives one derived resource view

The node journal records ownership and intent needed for recovery; host
inspection records what exists. BiotController combines them into `DataState`,
`InstallationState`, and the other NodeState fields before calling the pure
decision core. Reconciliation does not receive parallel local and observed
versions of the same resource.

This gives up independently manipulating every piece of recovery bookkeeping in
the decision function. In exchange, disagreements are resolved once at the
inspection boundary and clauses operate on product states such as `lost` and
`uninitialized`. Split those inputs again only if a decision genuinely needs
provenance that the derived state cannot carry.

### Restart is composed from simpler lifecycle changes

Stop completes only after container absence; a later start creates a new
incarnation. Rebuild selects a new Environment identity even when its selection
matches the previous one.

This exchanges one-call atomic restart and stop/start coalescing for a single
desired revision and direct environment matching. Add a restart token or command
only if the two-operation interaction is materially inadequate; do not restore a
second generation merely for naming symmetry.

### Retries use resource identity and revisions

PUT and DELETE policy operations are naturally idempotent, lifecycle writes use
an expected revision, and creation uses a caller-generated Biot ID. There is no
general request receipt ledger.

This exchanges replaying the exact original HTTP response for fewer permanent
records and simpler transaction paths. Add a request key and digest to Operation
only when a future mutation cannot be made structurally retry-safe.

### Stable URLs are derived rather than allocated

A publication exists only while its row exists. Its hostname is deterministically
derived with the deployment HMAC key and stored on that active row for routing
and uniqueness. Unpublish is ordinary deletion; republish derives the same URL
but does not restore deleted view grants.

The derivation key and version are durable operator state backed up with the
server database and do not rotate initially. This exchanges key rotation and
operator-selected hostnames for stable URLs without inactive allocation rows. If
either becomes necessary, store a permanent allocation or key version before
changing the derivation.

### Policy progress is per assigned node

The server records one access revision per biot and its assigned node reports the
highest applied revision. It does not persist one closure obligation per
connection.

This reports whether the enforcement point has applied policy, but cannot prove
that every historical stream produced a distinct close acknowledgement. A
withdrawal also interrupts unrelated sessions on the same Biot; clients must
reauthorize and reconnect. That small availability cost removes remote session
IDs and policy scopes from the recovery protocol.

### Environment resolution has one owner

A biot remains on one node. That node resolves each Environment once into an
atomic, inspectable location and reports the result. The server rejects a
different result for the same ID but does not arbitrate candidates or acknowledge
one before preparation.

This avoids a distributed resolution handshake. Migration, multiple builders,
or private remote evaluation would invalidate the single-owner premise and must
revisit this boundary explicitly.

### Environments remain per biot

Each Environment, Resolution, and prepared-artifact identity belongs to one Biot,
even when another Biot selects identical sources. Nix may deduplicate resulting
store content, but Biot does not cache evaluation or share mutable snapshots
across owners.

This accepts repeated evaluation for a few dozen development environments in
exchange for simple ownership and failure reporting. Introduce content-addressed
evaluation sharing only after measurements show that evaluation time matters and
the isolation rules for project snapshots are understood.

### Lost nodes remain visible rather than falsely cleaned

A node with allocations not known absent can be disabled but not retired. Its
destroyed Biots may therefore remain pending indefinitely.

This exchanges immediate administrative cleanup for an honest account of data
that may still exist and identity ranges that may still be in use. Add an
explicit abandonment state and operator action when a real lost-node recovery
workflow is designed; do not overload successful destruction or retirement with
that meaning.

### Server purity stops at transactional state

Desired transitions, authorization predicates, access scope, retry decisions,
and query projection are pure functions. Capacity, uniqueness, and mutation
ordering remain inside the SQLite transaction that establishes their truth.

This leaves those rules on the integration-test side of the testing boundary.
Extracting a pure write plan would also require duplicating a database snapshot
and its constraints, which is not a net simplification. Introduce such a plan
only when several persistence implementations need the same nontrivial decision,
not merely to increase the unit-test count.

### Abstractions follow implementations

The host begins as a concrete module, the process model specifies ownership
rather than a complete supervisor tree, and credentials are implemented one
integration at a time.

This gives up the appearance of a uniform architecture before its parts exist.
It prevents speculative callbacks, process groups, and credential transports
from becoming compatibility obligations. Extract them when a second concrete
case demonstrates common semantics.

The model is ready to build when the create-to-running slice can be implemented
from these values without reconstructing hidden protocols. Refine local module
and supervisor structure from that implementation, while revising a shared
contract only when evidence shows the smaller guarantee is insufficient.
