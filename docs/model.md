# Biot implementation model

This is the working implementation contract for [Biot](../README.md), building
on `README.md`. It defines the smallest model needed for the initial
system. Implementation details should remain local until a real failure or a
second implementation makes a broader abstraction useful.

The foundation is one server, a few fixed-assignment nodes, persistent working
data, and replaceable execution. Elixir/OTP implements the server and node as
separate releases, Phoenix the HTTP API and LiveView UI, Go the CLI and the
in-container agent, and Nix environment composition. There is no scheduler,
migration, ownership transfer, or independent node authorization policy.

Elixir-shaped signatures describe application boundaries. Record notation lists
semantic fields, omitting routine timestamps and storage encodings. These are
contracts, not a requirement for one module, process, or table per value.
Sections 2–8 define the contracts. Walkthroughs illustrate them, the evidence
table names checks, and section 11 explains the tradeoffs.

The lifecycle core exists, but this contract includes changes to that core and
new access features. It describes the intended system, not a claim that every
boundary is implemented. Initial credential support covers runtime secrets and
private source fetching. General credential mediation is deferred; section 11
records why.

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

### Show me access

```text
browser ──TLS──▶ edge ──HTTP──▶ server: dispatch on Host
ssh client ─────TCP────────────▶ server: OTP ssh daemon
                                   │
                                   │ session owner: authenticate, read policy,
                                   │ register, then open one stream
                                   │
                                   │ control link: open_stream(connection, revision, stream, biot, target)
                                   ▼
                                  node ── connects /biot/run/agent.sock ──▶ agent
                                   │                                         │
                                   │ new mTLS connection: attach(stream_id)  │ loopback port
                                   ▼                                         │ or shell PTY
                                 server ◀──── port bytes / shell frames ────┘
```

The server is the only policy enforcement point for previews, browser terminals,
and SSH. The node opens exactly the streams the server asks for and closes every
stream of a biot when its access revision rises. The agent inside the container
is the one door: it connects to loopback ports and runs shells, and only the node
can reach it.

## 1. Concepts, guarantees, and boundaries

A biot is a stable identity with independently owned working data. An environment
describes frozen source inputs. An installation makes a built environment
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
| Principal | One person, identified by the OIDC provider | Server database |
| Session | One control login, or a host-scoped preview session linked to that login | Server database |
| Credential | One revocable bearer token for the API and authorized previews | Server database |
| Session owner | The server process that admitted one stream and owns its lifetime | Owner registry |
| Stream | One byte stream from a session owner to a container port or shell | Owner and the node that opened it |
| Agent | Biot's process inside every container: loopback connect, PTY shells | Environment bundle; reachable only by the node |
| Build worker | Disposable isolated resource for one biot's Nix work | Node host implementation |
| Private Nix store | Software, Nix database, and retained roots belonging to one allocation | Assigned node filesystem |

The biot is also a shared trust boundary. A shell collaborator can change its
future behavior and use its credential grants. Revocation cannot undo either. A
view grant permits interaction with the published application; it does not make
that application read-only. Replacement changes execution, not arbitrary
persistent state. The agent runs inside that boundary: a shell collaborator can
replace it, and that changes only what other collaborators of the same biot see.

The implementation preserves these invariants:

| Requirement | Enforcement |
| --- | --- |
| Accepted intent survives lost replies and process restarts | Server transaction commits desired state and an operation; periodic revision comparison and synchronization redeliver it |
| Initialized data are never silently replaced | Node ownership metadata and inspection distinguish uninitialized, absent, present, and unknown |
| At most one container uses a biot's writable data | One BiotController serializes changes; replacement inspects absence before start |
| Failed or obsolete preparation cannot replace current execution | Build completes before installation; BiotController rereads current desired state before installation or start |
| Destruction is terminal | Server retains the destroyed biot identity; node acknowledges only inspected resource absence |
| Managed access follows server policy and is withdrawable | Every admission reads current policy; owned streams close after relevant committed changes or control loss |
| Every stream has one registered owner and one biot | The owner registers before it opens; an unknown stream ID cannot attach |
| A stream never outlives its control connection | Both sides close streams when the control link is lost or resynchronized |
| Bearer secrets are never stored in clear | Session tokens, credentials, and handoff codes are random; the server stores and looks up only their digests |
| Secret values never rest on the server | [Delivery and handling](#delivery-and-handling) keeps values at the node |
| New processes use current secrets | Generated entries follow the [runtime secret rules](#runtime-secrets) |
| Browser authority ends with its login | Preview sessions reference a control session; live connections own that proof and its expiry |
| A node stream reaches only its own biot | The node opens a [verified agent connection](#agent-connection) |
| Stale admission cannot join a newer stream group | Admission carries the control connection ID and access revision; group admission and retirement are serialized |
| User Nix cannot read node or neighboring data | Evaluation and builds run in an isolated worker with a private store and explicit mounts |
| Build cancellation ends owned build work | The node stops and inspects the whole worker before another writer or allocation cleanup |
| Process restart does not require remembered process state | BiotController begins with host inspection and converges from durable intent and ownership metadata |
| Controller recovery preserves running environments | Replacement controllers retain matching runtime containers and cancel surviving build workers |
| Environment sources stay fixed after resolution | Its manifest pins sources and platform; preparation uses the current node release |

| Boundary | Owns | Callers do not know |
| --- | --- | --- |
| Server application modules | Current authorization, transaction meaning, accepted result | SQL layout or node mailboxes |
| Server queries | Product meaning of intent, observation, and progress | Table joins and report encoding |
| Session owners and registry | Admission order, stream lifetime, and matching closure | Transport-specific process layout |
| Server streams | Stream IDs, attach matching, shell framing, and owner delivery | Node socket paths |
| `Biot.Node.Reconcile` | Next action from an execution spec and inspected state | Podman, filesystem, Nix, or messaging commands |
| Node host implementation | Parsed inspection and retry-safe resource effects | Callers' domain policy |
| Node streams and agent client | Opening, splicing, and closing streams for one biot | Who the user is or why the stream was allowed |
| Agent | Loopback connect, PTY, resize, exit, and process cleanup inside the container | Users, policy, or server records |
| Environment implementation | Nix resolution, build, retention, and launch bundle | Lifecycle and presentation code |

These are responsibility boundaries. Begin with concrete modules. Introduce a
behaviour or split a module only when another real implementation or separately
owned resource requires it. Tests use real temporary resources rather than
expectation-based mocks.

## 2. Server records and transitions

### Show me the server state

```text
Principal ──owns──▶ Biot ──selects──▶ Environment
   │  │  │          │  │
   │  │  │          │  ├──records───▶ Operation
   │  │  │          │  ├──reports───▶ Observation
   │  │  │          │  ├──grants────▶ ShellGrant
   │  │  │          │  ├──records───▶ possible direct-secret exposure
   │  │  │          │  └──publishes─▶ Publication ──grants──▶ ViewGrant
   │  │  │          │
   │  │  │          └──assigned to──▶ Node ──reports──▶ NodeObservation
   │  │  │
   │  │  └──logs in as──▶ Session(control) ◀──parent── Session(preview(hostname))
   │  └──holds──────────▶ Credential
   └──proves with───────▶ SshKey
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
  status: enabled | disabled

Session
  id_digest: Digest
  principal_id: PrincipalId
  scope: control | preview(Hostname)
  control_session_digest: Digest | none
  expires_at: Timestamp

Credential
  id: CredentialId
  principal_id: PrincipalId
  label: string
  secret_digest: Digest
  expires_at: Timestamp
  last_used_at: Timestamp | none

SshKey
  id: SshKeyId
  principal_id: PrincipalId
  public_key: SshPublicKey
  fingerprint: string
  label: string

PreviewHandoff
  code_digest: Digest
  hostname: Hostname
  control_session_digest: Digest
  challenge_digest: Digest
  return_path: SameOriginPath
  expires_at: Timestamp

Node
  id: NodeId
  registration: RegistrationId
  status: enabled | disabled | retired | abandoned
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
  direct_secret_exposure_possible: boolean

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

Manifest
  platform: Platform
  base_nixpkgs: PinnedSource
  layers: list(PinnedSource)
  digest: Digest

Publication
  biot_id: BiotId
  port: Port
  hostname: Hostname
  state: active | inactive

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
  waiting_for: none | fetch_credential(RepositorySource)
  failure: none | {target_revision, Failure}

AccessObservation
  biot_id: BiotId
  connection_id: ConnectionId
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
sharing. A principal with any grant on a biot may read it.

`BiotId` is a UUIDv4 accepted only in its canonical form. `BiotName` is a
lowercase DNS label of at most 63 characters that is not a canonical UUID, so a
client can tell a name from an ID without asking the server. Names are unique
among one owner's live Biots.
`RepositorySource`, `SourceSelector`, `PinnedSource`, `Hostname`, and `Port` are
parsed boundary values. Repository and source URLs accept
only HTTPS, with no embedded credentials. Local paths, `file://`, SSH, and Git
helpers such as `ext::` are rejected. `Platform` is a supported Nix host system supplied by the
assigned node; callers cannot select a different platform.

`SshPublicKey` is one OpenSSH public key line decoded with OTP `ssh_file`; its
`fingerprint` is the SHA-256 fingerprint OpenSSH prints. `SecretName` is an
uppercase environment variable name that is not one of the names the Nix schema
reserves. `SameOriginPath` is an absolute path with optional query, never a full
URL. `StreamId`, `CredentialId`, `SshKeyId`, `ArtifactId`, `ConnectionId`, and
`PrivateDiagnosticId` are opaque identifiers minted by their owning boundary.
`IncarnationId` is Podman's full native container ID, parsed as an opaque value.
It is not a Biot-generated UUID or a separately persisted identity file.

Session tokens, credential tokens, and handoff codes are 256 random bits. The
server stores their SHA-256 digest and looks up by that digest. The clear value
exists once: in the cookie, in the response that shows a new credential, or in
the redirect that carries a handoff code. Credential tokens carry a `biot_`
prefix so a leaked token is recognizable in logs and scanners.

A publication allocates its hostname once for the life of the biot. The label
encodes 128 random bits as lowercase, unpadded base32. Database uniqueness binds
that hostname to one `(biot_id, port)`. A collision returns `hostname_conflict`;
it never routes to another publication. Only an active row routes requests.
Unpublish sets it inactive and deletes its view grants in the same transaction.
Republish activates the same row and URL without restoring grants. See
[Stable URLs are allocated once](#stable-urls-are-allocated-once).

`NodePrivatePath` is a parsed path under the configured node data root and never
comes from an API caller. `ContainerState` is `running | exited(exit_status)`.
`Digest` is SHA-256 over a named canonical encoding. `Timestamp` is UTC time
recorded by the owning boundary. Revisions, not timestamps, order desired changes.

### Node status

Node status is one value, avoiding invalid combinations of flags. Enabled and
disabled alternate freely. Retired and abandoned are terminal.

| Status | Meaning | Connection | New biots and access |
| --- | --- | --- | --- |
| enabled | Normal service | Accepted | Allowed |
| disabled | Operator paused it | Accepted; containers may keep running | Rejected |
| retired | Operator ended it after every allocation was known absent | Rejected | Rejected |
| abandoned | Operator wrote off a lost node; data may remain | Rejected | Rejected |

Retirement is rejected while any assigned Biot's allocation is not known absent,
or while the node's latest NodeObservation lists an orphaned allocation. A node
that never reported has listed none.
Abandonment has no precondition. It records that the node's data and identity
ranges may still exist, and it never reports unobserved cleanup as destruction.
The abandonment transaction marks every pending or working Operation of an
assigned Biot `failed({stage: node, code: node_abandoned, retry: operator})`.
Afterwards only `destroy` is accepted for those Biots: it commits destroyed
intent, releases the name and policy records as usual, and records its Operation
as failed with the same failure, because no node will ever confirm removal.
Other lifecycle changes return `node_abandoned`. An abandoned node that
reconnects is rejected with `registration_abandoned`; the operator wipes it and
enrolls it under a new Node ID.

### Operator enrollment

Nodes are enrolled through operator configuration read at startup or explicit reload. The
operator generates stable opaque Node and Registration IDs and provisions each
node's private key and certificate using operator-managed tooling. Server
configuration binds the registration to that Node ID and authenticated peer
identity, supplies `max_biots` and the requested status, and configures trusted
server identity on the node. A registration ID alone is not a credential. The
node reports its platform in the handshake, before becoming ready.

Startup and reload use the same transaction to import registrations and apply
status changes. Startup completes it before accepting connections.
Repeated configuration is unchanged;
omitted non-retired registrations become disabled, never deleted; omitted
terminal registrations stay terminal. Disabling applies the access-revision
changes in section 5. Retirement checks the allocation precondition above;
abandonment applies the Operation failures above. An invalid transition rejects
the entire configuration update. Terminal registrations remain tombstones and
cannot be enabled again. Node and Registration IDs remain stable when an
operator replaces a node's peer key. The replacement commits the new peer
identity, closes the old control connection and streams, and rejects the old
identity on subsequent connections. Renewal under the same peer key also keeps
the existing IDs and allocations.

Only the deployment operator can change this configuration; OIDC users have no
node administration API. Certificate issuance commands and protected key-file
layout belong to deployment implementation. See [Node administration is operator
configuration](#node-administration-is-operator-configuration) for the tradeoff.
The enrollment file remains authoritative. An explicit release command reloads
it; there is no second administration database, API, or automatic file watcher.
An invalid reload leaves the running configuration intact.

Any authenticated principal may resolve a known email address and list nodes.
This intentionally reveals membership and capacity within the one-provider,
trusted-group deployment; neither is a public discovery endpoint.

Use foreign keys and database uniqueness for facts the database can enforce:

```sql
CREATE UNIQUE INDEX principal_identity ON principals (issuer, subject);
CREATE UNIQUE INDEX session_digest ON sessions (id_digest);
CREATE UNIQUE INDEX credential_digest ON credentials (secret_digest);
CREATE UNIQUE INDEX ssh_key_fingerprint ON ssh_keys (fingerprint);
CREATE UNIQUE INDEX preview_handoff_code ON preview_handoffs (code_digest);
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
constraint is therefore also the referenced resource identity. A grant requires
an active publication in the transaction; unpublish explicitly deletes grants.
Sessions, credentials, and SSH keys reference their principal; principals are
never deleted. A preview session references its control session with
`ON DELETE CASCADE`; a handoff does the same. Control sessions have no parent.
The session boundary enforces that a preview's parent is a control session for
the same principal, and that the preview cannot expire later than its parent.
Expired rows are swept; reads and live connection deadlines enforce expiry.

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

The manifest freezes source inputs and platform, not Biot's implementation.
Preparation uses the current node release's schema, generator, agent, and toolchain.
The node does not retain old build support to reproduce earlier artifacts.
Rebuild selects a new Environment and picks up current build support.
An upgrade alone leaves intact prepared artifacts and installations in place.

If an artifact must be built again, current support may produce a different
Artifact ID from the same manifest. Installation follows the normal replacement
rules; a matching Environment ID does not make different artifacts interchangeable.

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

Presentation code calls ordinary application modules, not server processes.
Domain modules own commands and focused reads, such as `Operations.get` and
`Secrets.list`. `Queries.Biots` and `Queries.Nodes` compose product views across
those domains. The split follows responsibility, not whether a function reads
or writes. Callers do not need a separate query module for every lookup.

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

Secrets.deliver(actor, biot_id, name, value)
Secrets.remove(actor, biot_id, name)
Secrets.list(actor, biot_id)
FetchCredentials.deliver(actor, biot_id, source, value)
FetchCredentials.remove(actor, biot_id, source)

Login.start(return_path)
Login.finish(login_state, callback_params)
Sessions.control(token)
Sessions.preview(hostname, token)
Sessions.logout(token)
Credentials.create(authentication, label, expires_at)
Credentials.revoke(actor, credential_id)
Credentials.list(actor)
Credentials.authenticate(token)
SshKeys.add(actor, public_key_line, label)
SshKeys.remove(actor, ssh_key_id)
SshKeys.list(actor)
SshKeys.authenticate(public_key)
PreviewHandoff.begin(authentication, hostname, challenge_digest, return_path)
PreviewHandoff.finish(hostname, code, challenge)

Access.open_preview(authentication, hostname)
Access.open_shell(authentication, biot_id, %ShellRequest{})

Queries.Biots.get(actor, biot_id)
Queries.Biots.list(actor, page)
Queries.Nodes.list(actor)
Operations.get(actor, operation_id)
Diagnostics.get(actor, diagnostic_ref)
RuntimeLogs.get(actor, biot_id, max_bytes)
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
  | node_disabled | node_abandoned | capacity_exceeded
  | temporarily_unavailable

AdmissionError =
  unauthenticated | not_found | forbidden
  | node_unavailable | agent_unreachable | port_not_listening
  | too_many_streams | timeout

Failure =
  {stage, code, retry: automatic | after_change | operator,
   message, diagnostic_ref: none | PrivateDiagnosticId}
```

Authentication functions return `{:ok, Authentication}` or `:error` with no reason.
The caller cannot learn whether a token is unknown, expired, or scoped elsewhere.
`Sessions.control/1` accepts only control-scoped rows; `Sessions.preview/2`
accepts only a preview row scoped to exactly that hostname. Both refresh nothing:
lifetimes are absolute.

`Authentication` pairs an Actor with its proof, as defined in section 5.
Request boundaries check the proof before calling application functions with
the Actor. Live connections retain it and recheck it before each action.

A lifecycle change other than destroy against a destroyed Biot returns
`destroyed`; the Biot remains readable.

### Diagnostics and runtime output

The node retains a bounded diagnostic log for the latest failed attempt of each
Biot revision and returns its `PrivateDiagnosticId` with the Failure. The actor
who initiated the Operation for that revision or the Biot owner may fetch it through
`Diagnostics.get`, both while the node retries and the Failure is only in the
Observation, and after the Operation fails. The server retrieves it from the
assigned node on demand.
`Diagnostics.get` returns `ok({content, truncated}) | error(CommandError)`.
An unavailable node or an expired fetch deadline returns
`temporarily_unavailable`; a missing or expired diagnostic returns `not_found`.
The server enforces a finite configured deadline and byte limit, also sent with
the request so the node can bound its response. It releases pending request
state on timeout or disconnect and ignores late replies. A bounded log excerpt
indicates truncation. Exact limits, redaction, and local retention counts belong
to implementation, but the latest current-revision failure must remain useful
enough to diagnose.
Capture enforces the byte bound while output arrives, including temporary files.
Reading only a bounded tail after an unbounded capture is insufficient.
Diagnostic files and their IDs live outside runtime mounts and survive reader
or controller restart. Node retention limits apply across completed revisions
and destroyed allocations; the server does not retain another copy.

Runtime output has a separate node query: `RuntimeLogs.get` returns a bounded
tail with `{incarnation_id, content, truncated}`, or `error(CommandError)`.
Only the owner or a current shell collaborator may read it. The node retains
bounded stdout and stderr from the service runner outside runtime-writable mounts.
This includes service names and exit messages for the current or most recent
incarnation. The same request
deadline and response bounds used by diagnostics apply. Missing logs return
`not_found`; an offline node returns `temporarily_unavailable`.

A running container does not imply healthy services. Operation success confirms
the lifecycle result only. The UI and CLI expose runtime logs even when the
Operation succeeded, so users can diagnose a service that exits inside it.
The [secret handling rules](#delivery-and-handling) govern private workload output.

### Lifecycle and policy results

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
    insert Biot with Desired(revision=1, command.initial_state, environment), access_revision=1
    set direct_secret_exposure_possible=false
    insert Environment owned by that Biot
    insert pending create Operation targeting revision 1
  after commit, best-effort wake the assigned node
```

The server periodically compares desired revisions with current-connection
accepted revisions and redelivers missing intent. Startup and reconnect perform
the same comparison. A lost wakeup cannot leave work pending indefinitely on a
healthy connection. This uses the existing Biot and Observation records, without
a durable message queue.

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
deactivates the Biot's publications, deletes explicit grants, and increments its
access revision before lifecycle cleanup begins. Unpublishing deletes the matching view
grants, so republishing restores the URL but not previously shared access.

Node reports are authenticated to a current registration and checked against
assignment and desired revision. A stale report cannot complete newer work. An
operation stays `working` while the node retries automatically or waits for a
fetch credential. Attempt failures remain visible in Observation and diagnostics.
Only exhausted retries or failures requiring a lifecycle change or operator
repair make it `failed`. A terminal Operation remains historical if later work
makes the Biot healthy.

| Kind | Completion evidence |
| --- | --- |
| Create | Desired environment installed; container running or absent according to the requested initial state |
| Start | Desired environment installed and a running container |
| Update environment | Desired environment installed; running container if requested |
| Stop | Container absent after inspection |
| Destroy | Container, data, and allocation absent after inspection |

Completion checks follow the Operation's kind. Once execution is absent, a stop
succeeds even if later preparation fails. A stopped create or rebuild still
requires its selected environment to be installed.

### Secrets

Runtime secrets enter the Biot. Source credentials stay with the node and
authenticate private checkout and layer fetches before a runtime exists.

| Kind | Node storage | Consumer | Server record |
| --- | --- | --- | --- |
| Runtime secret | Private `secrets` directory, mounted at `/biot/secrets` | Service and shell entries | Permanent possible-exposure marker |
| Source credential | Private files outside runtime and user build mounts | Trusted fetch process | None |

#### Delivery and handling

Both kinds use synchronous requests over the mutually authenticated control link.
Delivery and removal require the current owner, a non-destroyed Biot, a ready
node, and an existing allocation. They return `ok | error(CommandError)`.
A missing allocation or failed, cancelled, or timed-out delivery returns
`temporarily_unavailable`. A lost reply leaves the outcome uncertain.

BiotController serializes writes, removals, and listing between lifecycle actions.
It writes files atomically and never creates an allocation to service a request.
This orders secret changes against start and destruction. Concurrent mutation
during a long build is deferred; requests wait only until their deadline.
The node drops queued work when that deadline expires. Once a write starts,
a lost reply cannot undo it.

Repeating delivery replaces the same file; removing an absent file succeeds.
Files survive controller restart and disappear with allocation destruction.
The node never journals values. The server never persists them or queues them
for later delivery.
A value is at most 64 KiB. The limit is a protocol constant, not a setting,
because both releases size the control link's frame limit around it.

Clients read values through hidden prompts or stdin and never put them in
arguments or persist them for retry. Secret values belong to neither the
creation body nor its fingerprint. UI fields are masked and cleared after use.

Biot logs filter `value` and authentication fields, including
`X-Biot-Authorization`. Codecs and OTP crash reports expose fixed error codes
and metadata, never payloads or pending values. Source credentials also stay
out of checkout configuration, manifests, and diagnostics.
These handling rules apply at every transport and process boundary.

User workloads can write supplied secrets to their own output. That output
remains private and is never copied into server or node operational logs.

#### Runtime secrets

`Secrets.deliver` records possible exposure before sending the value:

```text
Secrets.deliver(actor, biot_id, name, value):
  transaction:
    require current owner and a live Biot
    set direct_secret_exposure_possible=true
  deliver to the assigned node using the shared delivery rules
```

The marker remains true even if delivery fails or its reply is lost.
Neither removal nor destruction clears it, because exposure cannot be undone.
`biot list` labels a marked Biot as "may contain supplied secrets".

`Secrets.list` returns current names as `ok(list(SecretView)) | error(CommandError)`
through the same owner-only node boundary. An offline node returns
`temporarily_unavailable`, not a stale or empty list. There is no value-read API
or per-name server history.

Each file appears at `/biot/secrets/<NAME>` after delivery. Nix-generated service
and shell entries start with a clean environment, load bundle and service
configuration, then export current secret files. The schema reserves names
needed by the launcher and agent. Only approved launch values, such as `TERM`
and terminal size, pass from the agent.

The service runner and agent never inherit secret values. New services and
shells see current files, including removals; existing processes keep their
environment. Removing a file cannot erase copies already held by a workload.

#### Source credentials

`FetchCredentials.deliver` accepts an HTTP authorization value scoped to one
parsed HTTPS source URL. It rejects control characters and invalid HTTP field
values. Only trusted fetching code can read the corresponding file.

The fetcher passes the value through a private descriptor to its fetch process,
with a clean environment. It restricts use to the source's origin and repository
path. Redirects cannot forward it to another scope. The fetch phase closes all
credential descriptors before handing content to a separate user build worker.
User evaluation and builds never inherit a credential-bearing process or mount.

A fetch needing credentials reports `waiting_for: fetch_credential(source)` and
ends its action. The Operation stays `working`; waiting consumes no retry budget.
Delivery wakes the controller to retry that fetch. Removal prevents later uses,
but cannot erase values already held by a fetch process. Source credentials
do not set the runtime-secret exposure marker.

#### Creation with credentials

`%Create{}` accepts `initial_state: running | stopped`, defaulting to running.
The CLI and UI choose stopped when supplying initial credentials:

1. Create the Biot and wait for its allocation.
2. Deliver any source credentials, then wait for preparation.
3. Deliver any runtime secrets and await each reply.
4. Start using the current desired revision.

A failed or uncertain delivery leaves the Biot stopped. The API and UI show
the source needing access if creation or a later rebuild waits for credentials.
General GitHub token issuance and credentials for runtime tools remain deferred.

### Queries

```text
BiotView
  id, name, owner_id, node_id
  role: owner | collaborator({shell: boolean, view_ports: list(Port)})
  desired: Desired
  environment: EnvironmentSelection | none
  actual:
    never_reported
    | {received_at, freshness: current | stale,
       installed_environment: EnvironmentId | none,
       container: unknown | absent | {incarnation_id, state},
       data: no_allocation | unknown | uninitialized | present | lost,
       waiting_for: none | fetch_credential(RepositorySource),
       failure: none | {target_revision, Failure}}
  node: connecting | ready | unavailable | disabled | retired | abandoned
  operation: OperationView | none
  access: {revision, enforcement: applied | pending(NodeId)}
  publications: list({port, url})
  direct_secret_exposure_possible: boolean

OperationView
  id, kind, target_revision, outcome

AccessView
  owner_id
  shell_grants: list(PrincipalId)
  view_grants: list({port, principal_id})

AccessDisplayView
  owner: PrincipalView
  grants: list({kind: shell, principal: PrincipalView}
               | {kind: view, port: Port, principal: PrincipalView})

NodeView
  id, status, platform, max_biots
  assigned_biots: non_negative_integer
  connection: connecting | ready | unavailable
  orphans: never_reported | {reported_at, allocations: list({biot_id, uid_range})}

SecretView
  name

DeploymentView
  publication_domain: string
  ssh: {host: string, port: Port,
        host_keys: list({type, public_key, fingerprint}) | absent}
```

The server owns these projections. Observations are last reported facts, not a
promise of current liveness. Freshness is derived: an Observation is current only
while its connection ID is the node's current healthy connection; it is never a
stored flag. BiotView projects current failure from the latest Observation. A
matching nonterminal Operation may become failed, but a terminal Operation
remains historical even if the container later exits. The node retains the local
retry state needed to avoid repeating a deterministic failure.

`Queries.Biots.list` returns the Biots the actor owns and the Biots on which the
actor holds any grant. `role` tells the UI and CLI which actions to offer.
`BiotView.publications` and `Publications.discover` include only active ports the
actor may view. Owners see all active publications; a shell grant alone does not
grant view access. Query projections enforce this rule before presentation.
Only owners receive the secret list and full grant lists.
`assigned_biots` counts every Biot still holding capacity. `NodeView.orphans`
replaces the log-only orphan reporting of the first slice.

### HTTP API

Routes are thin mappings to the application functions above. JSON uses string
tags and opaque IDs. The API authenticates with `Authorization: Bearer` only, so
it has no cookies and no CSRF surface. Browser pages are LiveView and call the
application modules directly; they never call `/api`.

| Method and path | Calls |
| --- | --- |
| `GET /api/me` | The actor's principal |
| `GET /api/deployment` | `DeploymentView` |
| `GET /api/nodes` | `Queries.Nodes.list` |
| `GET /api/principals?email=` | `Principals.resolve_email` |
| `GET /api/biots` | `Queries.Biots.list` |
| `PUT /api/biots/:id` | `Biots.create` |
| `GET /api/biots/:id` | `Queries.Biots.get` |
| `DELETE /api/biots/:id` | `Biots.destroy` |
| `POST /api/biots/:id/start` | `Biots.start` with `expected_revision` |
| `POST /api/biots/:id/stop` | `Biots.stop` with `expected_revision` |
| `POST /api/biots/:id/environment` | `Biots.update_environment` with selection and `expected_revision` |
| `GET /api/biots/:id/publications` | `Publications.discover` |
| `PUT /api/biots/:id/publications/:port` | `Publications.publish` |
| `DELETE /api/biots/:id/publications/:port` | `Publications.unpublish` |
| `GET /api/biots/:id/grants` | `AccessDisplayView.get` |
| `PUT` and `DELETE /api/biots/:id/grants/shell/:principal_id` | `Access.grant_shell`, `Access.revoke_shell` |
| `PUT` and `DELETE /api/biots/:id/grants/view/:port/:principal_id` | `Access.grant_view`, `Access.revoke_view` |
| `GET /api/biots/:id/secrets` | `Secrets.list` |
| `PUT /api/biots/:id/secrets/:name` | `Secrets.deliver` |
| `DELETE /api/biots/:id/secrets/:name` | `Secrets.remove` |
| `PUT`, `DELETE /api/biots/:id/fetch-credentials` | `FetchCredentials.deliver`, `remove`; body contains the source URL |
| `GET /api/operations/:id` | `Operations.get` |
| `GET /api/diagnostics/:ref` | `Diagnostics.get` |
| `GET /api/biots/:id/logs` | `RuntimeLogs.get` with a bounded `max_bytes` |
| `GET /api/credentials`; `DELETE /api/credentials/:id` | `Credentials.list`, `revoke` |
| `GET`, `POST /api/ssh-keys`; `DELETE /api/ssh-keys/:id` | `SshKeys.list`, `add`, `remove` |

Accepted lifecycle changes return 202 with an operation `Location`. `Unchanged`
returns 200. Committed policy changes return 200 with their access revision and
current enforcement state. Only the control account page issues credentials,
using a current control-session proof and CSRF protection.
Creation is `PUT /api/biots/:id`, making the caller-generated ID part of its
retry semantics.

| CommandError | Status |
| --- | --- |
| `unauthenticated` | 401 |
| `forbidden` | 403 |
| `not_found` | 404 |
| `invalid_input` | 422 with field errors |
| `revision_conflict`, `destroyed`, `creation_conflict`, `name_conflict`, `hostname_conflict`, `node_disabled`, `node_abandoned`, `capacity_exceeded` | 409 with the tag and any detail |
| `temporarily_unavailable` | 503 |

Error bodies are `{"error": "<tag>", ...}` with the tag's fields flattened
beside it, such as `current_revision`.

`invalid_input(field_errors)` carries a map from field names to lists of
`FieldReason` values. `FieldReason` is a closed vocabulary of 19 reasons, and
`CommandError` has 13 closed tags. An emitter that supplies a reason outside
that vocabulary raises a programming error instead of sending an unknown
sentence to a person. `BiotWeb.UserMessage` checks that every declared reason
has exactly one sentence at compile time. The same table supplies the web
wording and the generated `cli/internal/api/error_vocabulary.txt` embedded by
the Go client; `mix biot.check_cli_error_vocabulary` fails when that artifact
drifts. The Go client does not start if it cannot render every vocabulary
message it might receive: missing sentences, missing declared remedies, and
undeclared remedies all fail its startup checks.

Each sentence states the fact. Three reasons also carry a client-specific
remedy:

| Reason | Web UI | CLI |
| --- | --- | --- |
| `unauthenticated` | Sign in again. | Run `biot login`. |
| `revision_conflict` | Reload and try again. | Run the command again. |
| `publication_not_active` | Reload and choose an active one. | Choose an active publication. |

### Browser UI

The LiveView UI covers the same application functions as the API and adds the
terminal. It never calls `/api`.

| Page | Shows and offers |
| --- | --- |
| `/biots` | The actor's owned and shared Biots with role, node, and status; create |
| `/biots/new` | Repository, name, node, layers, optional runtime and source-fetch credentials |
| `/biots/:id` | BiotView, current Operation and its diagnostic, runtime logs, publications with URLs, grants by email, secrets by name, source credential requests, start, stop, rebuild, publish, share, destroy |
| `/biots/:id/terminal` | Ghostty Web terminal for owners and shell-grant holders |
| `/account` | Credentials and SSH keys; the server's advertised SSH host keys, types, fingerprints, and comparison endpoint; the one-time token display |
| `/nodes` | NodeView list with orphans |
| `/login`, `/logout`, `/preview/authorize` | OIDC round trip, session end, and the handoff step |

Actions a role does not permit are absent, not disabled. Lifecycle buttons send
the revision the page last loaded, so a `revision_conflict` reloads the page.

### Command-line client

The Go CLI drives only the HTTP API and stores one server URL and credential
token in the user's configuration directory. Names are resolved among the Biots
the actor can read; an ambiguous name is an error that asks for the ID.

| Command | Calls |
| --- | --- |
| `biot login [SERVER_URL]`, `biot logout` | `login` uses the supplied server URL (or prompts for one), opens its account page, reads the pasted token, verifies with `/api/me`, and stores the URL and token; `logout` removes them |
| `biot create --repo URL --name N [--node ID] [--layer SRC]... [--secret NAME]... [--fetch-credential URL]...` | With credentials: create stopped, deliver fetch credentials after allocation, await preparation, deliver runtime secrets, then start |
| `biot list`, `biot show N`, `biot wait N` | Views and operation polling |
| `biot start`, `stop`, `restart`, `rebuild`, `destroy` | Lifecycle; `restart` is stop, wait, start |
| `biot publish N PORT`, `unpublish`, `urls` | Publications |
| `biot share N --to EMAIL (--port PORT | --shell)`, `unshare`, `grants` | Email resolution, then grants |
| `biot secret set N NAME [--stdin]`, `secret rm`, `secret list` | Secrets; set reads a hidden prompt by default |
| `biot fetch-credential set N URL [--stdin]`, `rm` | Source credentials; values come from a hidden prompt or stdin |
| `biot diagnose N` | The current failure's diagnostic |
| `biot logs N` | A bounded tail of runtime output |
| `biot ssh N [--identity FILE] [-- COMMAND]` | Writes the advertised host keys from `DeploymentView` to a temporary `known_hosts`, then runs SSH with strict host-key checking and no global known-hosts file; refuses when no host key is advertised |
| `biot ssh-key add FILE`, `list`, `rm` | SSH keys |
| `biot token create`, `list`, `revoke` | Create opens the control account page; list and revoke use the API |
| `biot nodes` | `NodeView` list |

`biot create --secret NAME --stdin` reads one value from stdin; multiple names
use separate hidden prompts. Both clients follow the
[delivery and handling rules](#delivery-and-handling).

`biot create` reports `biot ready` only after the running Operation succeeds.
With initial credentials, this is the later start Operation. Readiness means the
container runs; it does not promise that each service is healthy.

## 4. Node state and reconciliation

### Show me node ownership

```text
Allocation
├── UID/GID range
├── network
├── checkout, home, and service data
├── run (agent socket), runtime secrets, and private fetch credentials
├── private Nix store, database, roots, and build scratch
├── disposable build worker
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
record supplies its manifest; sending that value back to its producer
would introduce another copy that could disagree. The access boundary consumes
`BiotSpec.access_revision`, while reconciliation consumes only `execution`.

The node persists intent, ownership, and recovery facts that host inspection
cannot reconstruct safely:

```text
Allocation
  biot_id: BiotId
  uid_range: {start, count}
  data_root: NodePrivatePath
  network_id: NetworkId
  initialization: uninitialized | complete

Installation
  biot_id: BiotId
  environment_id: EnvironmentId
  artifact_id: ArtifactId

Resolution
  environment_id: EnvironmentId
  manifest: Manifest

LocalIntent
  biot_id: BiotId
  biot_spec: last accepted BiotSpec
  destruction_report: none | final ExecutionReport

RetryState
  biot_id: BiotId
  target_revision: positive_integer
  attempts: map(stage, non_negative_integer)
  next_attempt_at: Timestamp | none
  failure: none | Failure
  waiting_for: none | fetch_credential(RepositorySource)
```

The node builds one reconciliation view by joining that metadata with host
inspection:

```text
Resource(T) = unknown(InspectionFailure) | absent | present(T)
DataState =
  no_allocation
  | unknown(Allocation, InspectionFailure)
  | uninitialized(Allocation)
  | present(Allocation)
  | lost(Allocation)
InstallationState =
  nil
  | unknown(Installation, InspectionFailure)
  | present(Installation)
  | lost(Installation)
ResolutionState =
  unknown(Resolution, InspectionFailure)
  | present(Resolution)
  | lost(Resolution)

NodeState
  data: DataState
  resolutions: map(EnvironmentId, ResolutionState)
  installation: InstallationState
  container: Resource({incarnation_id, biot_id, environment_id, state})
  prepared: map(EnvironmentId, Resource(ArtifactId))
  pending_exit: nil | {incarnation_id, exit_status}
  waiting_for: none | fetch_credential(RepositorySource)
  failure: nil | {target_revision, Failure}

CurrentAction = none | Action
```

Every `NodeState` belongs to one Biot. Its `resolutions` and `prepared` maps
contain only that Biot's Environments, and an Environment with no `resolutions`
entry is unresolved. Prepared roots use paths derived from Environment IDs.
Inspection covers desired, resolved, installed, and running Environments
independently. A missing root is `absent`; an unreadable root is `unknown` only
for that Environment. An unreadable obsolete root cannot hide a healthy desired
artifact. Reclamation never scans a sibling's artifacts. The host
checks that a release target belongs to the controller's Biot before removing
its owned root.

These derived states combine recorded ownership with inspection rather than
presenting journal and host copies to reconciliation separately. `unknown`,
`absent`, and `present` remain semantically distinct. Unknown blocks only actions
requiring that fact. A resource recorded as previously installed or initialized
but found absent is `lost`, not uninitialized. Ownership mismatch is an explicit
failure, never permission to adopt or delete an arbitrary resource.

Allocation metadata and initialization markers live outside writable mounts.
Initialization promotes staged data atomically and writes a completion marker
containing the Biot ID. The staging path also uses that ID. Allocation data
initialize once, so no separate initialization ID is needed.
If metadata says initialization completed and data are absent, the result
is visible lost-data failure, not another clone.

The node process takes an exclusive lock on its configured data root before
loading allocations. A second process cannot coordinate the same resources. A
released UID/GID range is not reusable until the prior allocation's runtime,
build worker, and data root are all inspected absent.

Loss of the lock, journal, or controller registry stops dependent management.
Supervision restores these prerequisites before controllers inspect and resume.
No new writer starts until exclusive ownership and existing worker ownership are
established. Useful runtime containers stay
running while management recovers; process restart alone does not retire them.

The container name derives from the Biot ID and stays stable across incarnations.
Inspection resolves that name to Podman's native ID and verifies allocation and
environment labels. A lost create reply therefore needs no remembered ID.
Retirement targets the exact inspected ID. A name collision with foreign labels
is an ownership failure; creation never uses `--replace` to remove it.

Prepared artifacts are roots in the allocation's private Nix store;
there is no second journal copy of their semantic state. Installation is an
atomic selection owned by the allocation. Removing an installation releases its
root only after no current container or in-flight action needs it.

`environment_release` owns eventual reclamation. A resolution's staged inputs and
prepared artifact remain retained while their Environment is desired, installed,
or used by a live container; resources outside those sets are releasable.
Reclamation never runs while an action is in flight. Its inputs remain retained
until completion or inspected cancellation, including during controller recovery.
Once desired is `destroyed`, only the live container's
environment is retained; the installed environment is released. A missing
installed artifact makes the Installation lost. Missing staged inputs
prevent preparing that Environment but does not invalidate an intact
installed artifact. The concrete rooting and collection schedule belongs to the
environment implementation.

### Private directories and the container

Each allocation's private root holds its runtime data and private build storage:

| Host directory | Mount | Mode | Purpose |
| --- | --- | --- | --- |
| `checkout`, `home`, `service-data` | `/biot/checkout`, `/biot/home`, `/biot/service-data` | rw | Working data |
| `run` | `/biot/run` | rw | The agent's Unix socket `agent.sock` |
| `secrets` | `/biot/secrets` | ro | One file per delivered secret |
| Private `nix/store` | `/nix/store` | ro | Only this biot's software |
| Private Nix database, roots, and build scratch | Not mounted in runtime | — | Build and retention state |
| Fetch credentials | Not mounted in runtime or user build workers | — | Scoped credentials for trusted fetching |

`allocate` creates these directories; `remove_data` removes them after all
runtime and build workers are inspected absent. The runtime never mounts a Nix
daemon socket or `/nix/var`. It mounts only its own store at `/nix/store`.

The container's private network is created with cross-network isolation
(`isolate`), because rootless bridge networks share one network namespace and
would otherwise route to each other.

#### Agent connection

The node connects through `run/agent.sock` under the allocation's root. Before
sending any target, it reads `SO_PEERCRED` from the connected Unix socket and
requires the peer's host UID to lie in that allocation's mapped UID range.
The path alone proves nothing: a collaborator can replace it with a symlink.
The kernel's connected-peer credentials avoid a path-check race and reject
neighboring agents or unrelated host sockets. A mismatch closes the socket and
returns `agent_unreachable`. No other runtime or builder mounts that `run`
directory.

Agent reachability, streams, and secret files are not part of `NodeState`.
Reconciliation neither waits for the agent nor manages streams. A stream that
cannot reach the agent fails at open time with `agent_unreachable`, and the
container's own lifecycle ends every stream when it stops.

### Pure decision core

```elixir
@spec next(ExecutionSpec.t(), NodeState.t(), CurrentAction.t()) ::
        :settled
        | {:run, Action.t()}
        | :cancel_current
        | {:blocked, BlockReason.t()}
        | {:failed, Failure.t()}
```

```text
BlockReason =
  inspection(InspectionFailure)
  | current_action(Action)
  | recorded_failure(Failure)
  | fetch_credential(RepositorySource)
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
Running ExecutionSpec + NodeState
          │
          ▼
     data_action ──not ready──▶ one action/block/failure
          │ ready
          ▼
 environment_action ─────────▶ one action/block/failure
          │ ready
          ▼
   execution_action ─────────▶ one action/block/failure
          │ ready
          ▼
   environment_release ───────▶ one action/block/failure/settled
```

`next` composes four small pure decisions:

1. `data_action` establishes or removes owned allocation and initialized data.
2. `environment_action` resolves, prepares, and installs environment resources.
3. `execution_action` retires or starts a container from the installed environment.
4. `environment_release` (`Environment.release/2`) releases resources outside
   the retained environments.

Destruction has priority and walks those resources in reverse ownership order.
`environment_release` runs second during destruction, after execution is ready.
Stopped intent first retires execution, even if data inspection or preparation
fails. It then converges data and the selected environment without starting.
Running intent establishes data and environment readiness before execution.
Each helper returns ready, an action, a block, or a failure;
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
| Control offline | Converge the last accepted durable intent; managed access stays closed |
| Fetch needs credentials | End the action and wait for delivery; keep the Operation working |
| Desired running; container exited | Retire it; after absence is observed, return an automatic-retry failure to the controller |
| Current revision has a recorded after-change/operator failure | Remain blocked; do not emit the same failure again |

The BiotController rereads the execution spec and inspected state after every
action. A preparation result carries no authority to install or start.
Stop cancels preparation when a live container must be retired first. It can
then resume preparation for the stopped intent. With no live container, useful
preparation can continue. Destruction cancels all preparation.
Cancellation stops the entire build worker.
No daemon computation is exempt from cancellation. Worker absence must be
inspected before conflicting work or allocation cleanup.

Cancellation progress, retry timing, and retry budgets belong to BiotController,
not the pure core. While an action is cancelling or a retry is backing off, the
controller starts no further lifecycle action. It continues bounded inspection
and reports changes even when an effect retry is blocked.
An automatic failure schedules bounded backoff;
repeated container exits eventually become an operator failure that remains
until desired revision changes. Exact delays and attempt limits are operator
configuration chosen with the host implementation.

`RetryState` survives controller and node restart. The controller records an
attempt before starting it, so a crash cannot reset the budget. Interrupted
attempts remain counted; inspection can still recover completed outputs.

Expected failures remain values, not restart signals. A relevant input change
clears its block; unrelated notifications do not.
Controller restart alone clears neither terminal failure nor exhausted attempts.
After restart, the controller clamps any saved retry delay to its configured
backoff bound; a wall-clock change cannot produce an indefinite wait.

Control connectivity is absent from the pure decision input. Only an actual
dependency, such as unavailable source credentials, can block local progress.

### Imperative shell and crash recovery

The concrete host implementation provides inspection, execution, and
cancellation. Do not introduce a behaviour solely to replace it with an
expectation-based mock.

```text
Node control ingestion receives desired intent:
  persist the newer BiotSpec locally
  notify the stream boundary of its access revision
  ensure its BiotController exists and notify it of execution intent

BiotController receives execution intent:
  load the durable execution spec
  inspect owned resources
  ask Reconcile.next for one action

BiotController runs an action:
  launch short work in a supervised, killable process group
  launch long build work in a disposable allocation-owned worker
  retain ephemeral task ownership

BiotController receives completion or task death:
  inspect affected resources regardless of reported success
  update ownership metadata from inspected evidence
  reload the current BiotSpec
  reconcile again

BiotController restarts:
  terminate owned helper process groups
  cancel surviving owned build workers and inspect their absence
  inspect runtime containers and completed outputs
  reconcile from durable intent, retry state, and allocation metadata
```

The stream boundary applies revisions independently of BiotController. After
closing the old group, it emits `access_applied(biot_id, revision)` on the current
control connection. Execution reports carry no access acknowledgement.
The server updates AccessObservation separately, so delayed execution reports
cannot overwrite access progress. A blocked build or controller failure cannot
delay stream closure. The controller never reads policy or opens streams.

An effect may complete immediately before its task dies. Allocation, promotion,
installation, container creation, and deletion therefore have stable owned
identities and converge when repeated. Short-lived command completion is never
trusted over subsequent inspection. See [Host work converges rather than
executing exactly once](#host-work-converges-rather-than-executing-exactly-once).

The build worker contains evaluation, builders, and any private Nix daemon.
Its stable allocation-owned name and labels let recovery find and cancel it.
Controller or node restart cancels surviving workers before another writer or
allocation cleanup. Unknown inspection blocks that work; foreign ownership fails.
No worker adoption, saved work description, or completion protocol is needed.

The build pool counts whole workers. Cancellation discards in-flight computation,
but the private store, completed artifacts, and staged inputs survive.
Reconciliation reuses those results and trusted cache substitutes when available.
It retries only work still needed by current intent. Matching runtime containers
remain running while build management recovers.

Each BiotController owns its own observation timer, backoff, and host actions.
A supervised Podman event reader wakes the matching controller on container
exit. Events are hints; inspection remains authoritative, and the controller's
periodic inspection repairs missed events.

A small starter populates the controller supervisor from LocalIntent at boot
and synchronization. It retains responsibility for failed starts until a child
exists. Normal controller crashes use supervisor restarts. The starter does
not inspect resources or run reconciliation for Biots. Restoring the registry
or dynamic supervisor also restores controllers from local intent, even offline.

After destruction is inspected complete, the controller saves its final report
in LocalIntent and exits normally. Its child specification uses `restart: :transient`,
so crashes restart it and completed destruction does not. The control
reporter periodically replays that report and includes it on reconnect.
Synchronization omits a completed destruction only after the server records it.
That omission releases the receipt; completed tombstones never need a permanent
controller. Until then, population skips them and reporting retains them.

BiotController also owns the short effects described under
[Delivery and handling](#delivery-and-handling). Secret values remain outside
desired state and NodeState.

## 5. Identity and managed access

This section fixes who a caller is, how a browser or client proves it, and how
an authorized caller reaches a container port or shell. Every path ends in a
stream opened through the node and closed by policy.

### Authentication surfaces

| Surface | Proves identity with | Produces |
| --- | --- | --- |
| Control host in a browser | Control session cookie `__Host-biot_session` | Actor and control session proof |
| HTTP API | `Authorization: Bearer biot_...` credential | Actor and credential proof |
| Preview host in a browser | Preview cookie `__Host-biot_preview` | Actor and preview proof linked to its control login |
| Preview host from a client | `X-Biot-Authorization: Bearer biot_...` | Actor and existing credential proof |
| SSH | Public key, on the server's SSH daemon | Actor and SSH key proof |

`Actor` is one struct holding the principal ID. Scope is enforced where the
token is read: a preview session cannot act on the control host or another
preview host, and a control session is never sent to a preview host. Cookies are
`__Host-` prefixed, `Secure`, `HttpOnly`, `SameSite=Lax`, path `/`, and carry no
`Domain`, so a preview application cannot set or read them for another host.

`Authentication` keeps identity separate from the proof that permits its use:

```text
Authentication = {actor: Actor, proof: AuthenticationProof}
AuthenticationProof =
  control(session_digest, expires_at)
  | preview(session_digest, control_session_digest, hostname, expires_at)
  | credential(credential_id, expires_at)
  | ssh_key(ssh_key_id)
```

Authentication returns no clear token to downstream code. A live connection
registers under the principal and proof before checking their current validity.
Browser connections also register under the root control session. They set an
absolute expiry timer and close when it fires. Logout deletes the control row
and its preview sessions and handoffs, then closes every registered connection
for that root login, including LiveViews, terminals, and preview WebSockets.

LiveViews recheck their proof before each event; each new SSH channel rechecks
its key and principal. A bounded periodic validity check closes idle connections
if a deletion commits but its notification is lost. The operator configures this
check interval alongside the control heartbeat bound. Ordinary HTTP requests
check validity on admission; already delivered bytes cannot be recalled.

The control cookie is the Phoenix session cookie renamed. It holds the session
token and the CSRF token and nothing else. Browser mutations pass Phoenix's CSRF
protection; LiveView and the terminal WebSocket check the exact configured
control origin. Preview origins receive no CORS headers from the control host.

### Login and control sessions

One OIDC provider is configured: issuer, client ID, client secret, and the
control host's callback URL. Login uses the authorization code flow with PKCE.

```text
Login.start(return_path):
  build state, nonce, and PKCE verifier
  return the provider's authorization URL and a signed, short-lived login_state cookie value

Login.finish(login_state, callback_params):
  verify state, exchange the code, verify the ID token and nonce with oidcc
  Principals.identify(issuer, subject, {email, name})
  require Principal enabled under operator configuration
  insert Session(control) with the configured lifetime
  return the clear session token for the cookie
```

An allowed provider identity becomes a Principal on first login. Restrict new
membership at the provider. Session lifetime is absolute and operator configured,
initially seven days. Logout ends that browser login across Biot, including all
preview hosts; other browser logins and CLI credentials remain independent.

Provider removal prevents new OIDC logins. It does not revoke Biot credentials
or SSH keys. An API credential cannot issue another credential.
To end existing authority, the operator disables an identity by issuer and subject
in configuration and explicitly reloads it. Startup applies that set before accepting requests,
including identities that have not logged in yet. Removing an identity from the
set re-enables it, but does not restore revoked proofs.
Repeated configuration makes no further changes to already disabled
principals or their access revisions.

Disabling a principal preserves ownership and history, deletes its sessions,
handoffs, credentials, and SSH keys, and increments access revisions on every
biot it owns or can access. It uses the same withdrawal recovery as grant removal.
Every authentication and application boundary requires an enabled principal.
There is no user administration UI or automatic OIDC directory synchronization.

### Bearer credentials

A credential is created on the account page, labeled, and shown once.
`Credentials.create` requires a current control-session proof, rather than only
an Actor. Bearer and preview proofs cannot mint independent credentials.
Its expiry is required and capped by an operator maximum, initially
90 days. `Credentials.authenticate` looks up the digest, rejects expired rows,
and records `last_used_at` coarsely. Revocation deletes the row and takes effect
on the next request; any live owner using that proof also closes.
The CLI holds one credential per server; `biot login` opens the account page
and reads the pasted token.

### SSH keys

`SshKeys.add` parses one OpenSSH public key line, stores it under the
principal, and rejects a fingerprint already registered to anyone. Removing a
key deletes the row and closes every SSH connection that authenticated with it,
because a removed key usually means a lost device. SSH connections register under
their key ID for that purpose.

### Preview login handoff

A preview host never runs the OIDC flow. It borrows the control host's login
through a single-use code bound to the exact host and the browser that asked.

```text
1. Browser requests https://<label>.<domain>/<path> without a valid preview session.
   The proxy sets __Host-biot_handoff=<challenge> for five minutes and redirects to
   https://<control>/preview/authorize?host=<label>&challenge=<sha256(challenge)>&return=<path>

2. The control host requires a control session, logging in first if needed.
   PreviewHandoff.begin(authentication, hostname, challenge_digest, return_path):
     require a current control session and an active publication with view authority
     insert PreviewHandoff linked to that control session for at most 60 seconds
     return the clear code
   It redirects to https://<label>.<domain>/__biot/callback?code=<code>

3. The preview host reads the handoff cookie.
   PreviewHandoff.finish(hostname, code, challenge):
     load by code digest; require unexpired, same hostname, sha256(challenge) match
     require parent control session valid, principal enabled, and current view authority
     delete the handoff row
     insert Session(preview(hostname)) linked to that control session
     cap expiry at the parent expiry
     return the clear session token
   It sets __Host-biot_preview, clears the handoff cookie, and redirects to return_path.
```

The challenge cookie binds the code to the browser that started the handoff, so
a code copied from a referrer or log cannot be redeemed elsewhere. `return_path`
is a same-origin path, never a URL. The path prefix `/__biot/` on every preview
host belongs to Biot and is never proxied.

Consumption and preview creation share one transaction. Every preview-session
lookup checks the parent login too. A handoff never creates an independent
seven-day login or renews the original login's authority.

### Session owners and admission

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
    Note over Node: Close all streams for Biot
    Node-->>Server: access_applied(Biot, r)
```

The response does not wait for node application. This example returns pending;
if acknowledgement has already arrived, it may return applied instead.

The revision is the durable target. Stream identities remain transient, and a
missed notification is recovered by comparing desired and observed revisions.

```elixir
Access.open_preview(authentication, hostname) ::
  {:ok, Stream.t()} | {:error, AdmissionError.t()}
Access.open_shell(authentication, biot_id, %ShellRequest{term, cols, rows, command}) ::
  {:ok, Stream.t()} | {:error, AdmissionError.t()}
```

The calling process is the session owner. It is the Plug process serving one
preview request, the WebSocket process behind one browser terminal, or the SSH
channel process for one shell. Each returns a live stream or an admission error.
The caller cannot use an authorization result to open an untracked stream.
Preview destinations are resolved by the node from the current biot and port,
never supplied as arbitrary host addresses.

Admission follows this ordering:

```text
register the calling process under the biot, principal, and proof, in checking state
read current proof validity, policy, and access_revision from one SQLite snapshot
if a close arrived or policy denies, stop
Streams.open(node_id, biot_id, access_revision, target) through the current node connection
mark the owner admitted
if a close raced with opening, close the stream immediately
```

Registration before the policy read matters. After a withdrawal commits, it
closes every registered owner for that Biot. An owner registered after that
enumeration necessarily reads the committed policy. An owner already registered
is found whether it is checking, opening, or admitted. Per-owner mailbox ordering
prevents a close received during checking from being forgotten. No global
admission coordinator or pre-transaction barrier is required.

The owner registry is an OTP `Registry` with duplicate keys. Owners register
under `{:biot, biot_id}`, `{:principal, principal_id}`, and their proof keys.
Browser proof keys include `{:control_session, digest}`; SSH uses `{:ssh_key, key_id}`.
Credential owners use `{:credential, credential_id}`. Closing
dispatches `{:biot_access, :close}` to every process under a key; an owner that
receives it closes its stream and its client transport. Owners monitor the
node's control connection process and close when it exits.

Policy predicates are pure and shared by every surface:

```elixir
Authorization.may_read?(actor, biot, grants)
Authorization.may_view?(actor, biot, port, view_grant_ids)
Authorization.may_shell?(actor, biot, shell_grant_ids)
```

Access changes use ordinary application transactions:

```text
withdraw access:
  authorize current owner and mutate the grant
  increment the affected biot's access revision
  commit
  close every local session owner for the biot
  deliver the new BiotSpec to its ready node
```

Revocation, unpublishing, and destroy use this path. Stopping needs no access
revision: retiring the container ends its streams. Granting access can commit
without closing streams or changing the revision. Disabling a node increments the
access revision of every assigned Biot in one SQLite transaction, then closes
the node connection. This broad write is reasonable for the fixed small node
capacity.

The node stream boundary owns one supervised group per biot, control connection,
and applied access revision. Stream children are temporary and never restart.
That boundary serializes admission with revision changes. A higher revision
blocks admission, terminates the old group, waits for every child to exit, and
creates an empty group for the new revision. Only then is the revision applied.
Repeating an applied revision sends its acknowledgement again. The server accepts
only assigned-node acknowledgements from the current connection, and access
progress never decreases within that connection.
An admission must match both the current connection and revision; an obsolete
request cannot join the new group. A future revision also returns `stale_access`;
the server must reread policy before retrying. The stream boundary never waits
inside admission for a revision change it must itself process.

The node knows no user policy or durable remote session IDs.
A disconnected node remains pending until its old connection exceeds the loss
timeout. At that point, managed access has closed and enforcement is applied
for the disconnected node. Reconnection must synchronize current revisions
before opening access. The UI reports node enforcement, not individual streams.

Access revisions only increase. Nodes ignore a revision below the highest one
they have applied; acknowledging a higher revision also acknowledges every lower
withdrawal.

This intentionally favors a small recovery protocol over precise remote closure;
see [Policy progress is per assigned node](#policy-progress-is-per-assigned-node).

Committed withdrawal cannot depend on the request process surviving. On server
start, node reconnection, and a periodic sweep, the server compares each Biot's
access revision with its current AccessObservation and repeats local owner closure and node
revision delivery while the assigned node is behind. An old admission arriving
after node application is rejected even if the original server request died.
The sweep operates on revisions, not durable session records.

A server crash closes every stream with its owner, because the owner holds the
server end of the socket. Node-side streams close after control-link loss
detection. This is the bound on revocation during server failure. There is no
promise to stop detached workload processes or undo filesystem changes made
through an earlier shell.

### Streams

A stream connects one server session owner to one target inside a container.
The control link admits it; traffic then uses its dedicated connection. Port
traffic is raw bytes. Shell traffic retains the same framing from agent to
server, including input, output, resize, and exit. The node does not move shell
events onto the control link.

```text
StreamTarget =
  port(Port)
  | shell(ShellRequest)

ShellRequest = {term: string, cols: positive_integer, rows: positive_integer,
                command: none | list(string)}

StreamFailure = unknown_biot | stale_access | agent_unreachable | port_not_listening | too_many_streams
```

```text
Streams.open(node_id, biot_id, access_revision, target):
  capture the ready control connection_id
  mint stream_id and register its owner, connection_id, and target kind, waiting
  send open_stream(connection_id, access_revision, stream_id, biot_id, target)
  await one of:
    a new node connection that attaches with this stream_id -> {:ok, stream}
    stream_failed(stream_id, reason)                          -> {:error, reason}
    the configured open timeout or control loss              -> {:error, timeout | node_unavailable}

Node on open_stream(connection_id, access_revision, stream_id, biot_id, target):
  require LocalIntent for biot_id                     else stream_failed(unknown_biot)
  require matching current stream group               else stream_failed(stale_access)
  require stream counts below the node and biot limits else stream_failed(too_many_streams)
  atomically admit one temporary child into that group
  open a verified agent connection                    failure -> stream_failed(agent_unreachable)
  send the target and parse a bounded reply
  port reply connection_refused                        -> stream_failed(port_not_listening)
  invalid reply or other agent failure                 -> stream_failed(agent_unreachable)
  open a new mutually authenticated connection to the server
  send attach(registration_id, connection_id, stream_id); await attached
  splice port bytes or bounded shell frames both ways
  shell exit travels after all shell output on this same connection
  EOF or protocol failure closes both sockets and ends the stream child
```

The node dials the server for every stream, so streams need no reachability the
control link does not already need. The attach connection uses the control
listener and the same mutual TLS. Its first frame is `attach` instead of
`hello`; the server checks that the registration exists, that the peer identity
matches it, and that the stream ID waits for that node and current control
connection.
It replies `attached`; the registered target kind determines raw port bytes or
shell frames. The peer cannot change the target kind during attach. Any
other case is `reject(unknown_stream)` and close.

After attach the owner process owns the server socket and reads it with
`active: :once`, so TCP flow control reaches the browser or SSH client without
an unbounded mailbox. `Streams` exposes shell data, resize, and exit as typed
events to terminal and SSH adapters; those callers do not parse wire frames.
Output is forwarded before exit status; EOF without an exit frame reports a
lost session, never success. Stream open timeout and per-node and per-biot limits
are operator configuration.

`stale_access` is internal to admission. Access rereads proof and policy before
a bounded retry within the original open deadline. It never relabels an old
authorization with a newer revision. Exhaustion returns `timeout` to the caller.

Each stream is its own connection so a slow browser cannot delay observations or
another biot's stream. One TLS handshake per stream is the price; see [Streams
are connections rather than a multiplexed channel](#streams-are-connections-rather-than-a-multiplexed-channel).

### Agent protocol

The agent listens on `/biot/run/agent.sock`. It unlinks a stale socket at start
and creates the new one with mode 0666 inside the allocation's private mount.
Only the node and processes in this biot can reach it. Each verified
[agent connection](#agent-connection) carries one target.

```text
node -> agent: one JSON line
  {"target": "port", "port": 3000}
  {"target": "shell", "term": "xterm-256color", "cols": 120, "rows": 40, "command": null | ["cmd", "arg"]}
agent -> node: one JSON line
  {"ok": true} | {"ok": false, "error": "connection_refused" | "invalid_request"}

port:  raw bytes both ways until either side closes
shell: frames of type(1 byte), length(4 bytes big-endian), payload
  server -> agent via node   0 data   1 resize (cols u16, rows u16)
  agent -> server via node   0 data   2 exit (status u8), then close
```

Request and reply JSON lines are at most 16 KiB, including the newline. Shell
frame payloads are at most 64 KiB; data senders split larger writes. Resize
payloads are exactly four bytes and exit payloads exactly one. Parsers check
lengths before allocating payload buffers. Unknown types, wrong direction,
invalid lengths, malformed JSON, or truncated frames close the stream.
The node validates untrusted agent frames; the server uses the same wire
contract. A replaced agent cannot force unbounded buffering.

After the shell exits, the agent drains remaining PTY output, sends the exit
frame, then closes. Output and exit therefore have one transport order.

A port target connects only to `127.0.0.1`. A shell target starts the bundle's
shell entry in a new session on a fresh PTY, with `TERM` set and the working
directory `/biot/checkout`; a `command` runs through the same entry instead of the
login shell. Every shell has a PTY, including SSH commands without one, so
stdout and stderr share the stream and no second channel is needed. When the
node's connection closes, the agent sends `SIGHUP` to the shell's process group
and `SIGKILL` after a short grace, then exits its handler. Foreground execution
ends with the stream; detached work is not promised.

The agent is a small Go program. Pinned dependencies are allowed where they
replace platform-sensitive code, such as PTY setup. Nix pins or vendors the
module graph so builds never depend on an unrecorded module download.
The agent is a derivation in the repository's `nix/` tree and
every bundle's closure includes it. The Elixir side parses agent replies at the
boundary through the shared shell codec; transport adapters receive typed events.

### Preview proxy

Every request whose `Host` ends in the publication domain is a preview request.
The endpoint dispatches on host before the router: publication hosts go to the
proxy, the control host goes to the router, and any other host is 404.

```text
preview request:
  if path starts with /__biot/: run the handoff callback
  label -> active Publication by hostname             else 404 "not published"
  if X-Biot-Authorization exists: authenticate the credential, or return 401
  otherwise: Sessions.preview(hostname, cookie), or begin the handoff redirect
  for a WebSocket upgrade: check its initiating Origin before opening a stream
  Access.open_preview(authentication, hostname)         (owner registration, policy, stream)
  forward the request on the stream, forward the response, close the stream
```

Every request reads current policy. That is the model's admission rule, not an
optimization to remove: revoking a view grant denies the next request and closes
open WebSockets through the owner registry.

Client previews reuse the existing Credential and the same per-port view policy.
An invalid explicit credential never falls back to a cookie or login redirect.
The proxy strips `X-Biot-Authorization` before forwarding. Application
`Authorization` remains untouched, so clients can satisfy both authentication
layers. Biot adds no preview-specific bearer token or broad preview CORS policy.

WebSocket upgrades using cookies require an Origin equal to the publication's
HTTPS origin. A sibling preview origin fails even when the cookie is valid.
A credential-authenticated client may omit Origin; if present, it must match.
The cookie identifies the user, not the page initiating the upgrade.
Cross-origin browser exceptions are outside the initial model.

Request rewriting removes hop-by-hop headers, every `X-Biot-*`, `Forwarded`, and
`X-Forwarded-*` header, and every cookie named `__Host-biot_*`.
The application's own cookies pass through. The proxy writes one authoritative
`X-Biot-Principal-Id`. It includes `X-Biot-Email` and `X-Biot-Name` only when known
and representable as valid HTTP field values without control characters.
Unsafe optional claims are omitted; they never alter the authoritative ID.

The proxy replaces forwarded headers with `X-Forwarded-Proto: https`, the routed
public host, and the client address established by the trusted edge. Ingress
accepts forwarded metadata only from configured edge peers. The edge discards
client-supplied forwarding headers before setting its own. `Host` is forwarded unchanged so
development servers with host checks see the public name. Response rewriting
removes hop-by-hop headers and any `Set-Cookie` naming a `__Host-biot_*` cookie,
so an application cannot replace Biot's authentication state. Bodies stream in
both directions. The proxy validates the WebSocket request and upstream upgrade,
then tunnels bytes through an HTTP adapter that exposes the upgraded connection.
Upgrade headers receive protocol-specific handling before the switch; ordinary
hop-by-hop removal must not destroy the handshake. After the upgrade Biot parses
and bounds application WebSocket frames, reassembles fragmented messages up to
`max_frame_bytes`, and forwards their opcodes and bytes without interpreting the
application payload. Socket ownership and bounded flow control still govern the
tunnel's lifetime.

One stream serves one HTTP request or one WebSocket. Upstream is HTTP/1.1. The
proxy renders small Biot pages for its own failures:

| Result | Response |
| --- | --- |
| Unknown hostname | 404, not published |
| `forbidden` | 403, no view access, with a link to the control host |
| `unauthenticated` or `unsupported_credential` | 401, sign in required |
| `node_unavailable` or `agent_unreachable` | 503, the biot is not running |
| `port_not_listening` | 502, nothing is listening on that port |
| `too_large` | 413, the request is larger than this Biot accepts |
| `too_many_streams` | 503, the Biot is busy; try again |
| `timeout` | 503, the Biot did not answer in time; try again |

### Browser terminal

The biot page offers a terminal to owners and shell-grant holders. It loads the
Ghostty Web front end from the control host and opens a WebSocket to
`/biots/:id/terminal/socket` with the control cookie and exact-origin check. The
WebSocket process is the session owner: it calls `Access.open_shell` with the
terminal's size, forwards binary frames as bytes in both directions, turns a text
frame `{"resize": {"cols", "rows"}}` into `Streams.resize`, and sends
`{"exit": status}` before closing when the shell ends. Ghostty Web is served as a
static asset of the control host, never from a preview host.

### SSH

The server runs OTP's `ssh` daemon on a configured port with operator-provided host
keys, at most one of each key type. Users connect with the Biot ID as the user name;
`biot ssh` builds the command from `DeploymentView` and refuses to open a session
unless the server advertises a host key to pin.

| Daemon rule | Setting |
| --- | --- |
| Public key only | `auth_methods` is `publickey`; `KeyCallback` is the key callback and delegates offered keys to `SshKeys.authenticate` |
| No forwarding | `tcpip_tunnel_in` and `tcpip_tunnel_out` stay false |
| No file subsystems | `subsystems` is empty, so sftp is not offered |
| One shell per channel | A custom `ssh_server_channel` bridges each session channel to one stream |

The channel process is the session owner. On `pty-req` plus `shell` or `exec`
it registers under the biot and its key, checks `may_shell?`, and opens a
`shell` stream with the requested size and command. `window-change` becomes a
resize. The agent's exit status becomes the channel's exit status. Every channel
on a reused connection admits itself again, so a revoked collaborator's next
channel fails even while their connection stays open. Removing the key closes the
connection itself.

## 6. Connection and transport boundaries

One mutually authenticated control connection exists per current node
registration. Its states are disconnected, synchronizing, and ready. A new
connection negotiates a protocol version before synchronization. The releases
reject a connection when they have no supported version in common.

One unique OTP Registry maps Node ID to the owning connection process. Its value
contains `{connection_id, readiness}` and changes through that owner's registry
entry. There is no separate process-membership table to keep synchronized.
Replacement closes the old connection before registering the new owner.
Losing the registry closes dependent connections; reconnect rebuilds readiness
from durable registration and synchronization.

```text
Node -> server:
  hello(registration_id, supported_protocol_versions, platform)
  attach(registration_id, connection_id, stream_id)

Server -> node:
  connected(connection_id, selected_protocol_version)
  | attached
  | reject(unsupported_protocol_version | registration_rejected
           | registration_retired | registration_abandoned | unknown_stream)

Server -> node:
  synchronize_begin(connection_id, count)
  synchronize_item(biot_spec)
  synchronize_end(connection_id)
  desired(biot_spec)
  diagnostic(request_id, diagnostic_id, max_bytes, timeout_ms)
  runtime_logs(request_id, biot_id, max_bytes, timeout_ms)
  open_stream(connection_id, access_revision, stream_id, biot_id, target)
  deliver_secret(request_id, biot_id, name, value, timeout_ms)
  remove_secret(request_id, biot_id, name, timeout_ms)
  list_secrets(request_id, biot_id, timeout_ms)
  deliver_fetch_credential(request_id, biot_id, source, value, timeout_ms)
  remove_fetch_credential(request_id, biot_id, source, timeout_ms)

Node -> server:
  synchronized(connection_id)
  observation(biot_id, execution_report)
  access_applied(biot_id, access_revision)
  resolution(environment_id, manifest)
  node_observation(orphaned_allocations)
  diagnostic_result(request_id, {content, truncated} | not_found)
  runtime_logs_result(request_id, {incarnation_id, content, truncated} | not_found)
  stream_failed(stream_id, reason)
  secret_result(request_id, ok | no_allocation | failure(code))
  secret_list_result(request_id, list(SecretName) | no_allocation | failure(code))
  fetch_credential_result(request_id, ok | no_allocation | failure(code))

Both:
  heartbeat(challenge) | heartbeat_response(challenge)
```

The first frame of a new connection is either `hello`, which starts a control
connection, or `attach`, which binds a stream to that control connection's version
after `attached`. Port streams then carry raw bytes; shell streams carry frames.
Only control connections negotiate a version and carry control messages afterwards.

The selected version governs every later message on the connection. Codecs
reject messages and fields outside that version. Version negotiation is part of
the initial lifecycle protocol; rolling-upgrade compatibility is added only when
there are two released versions to support.

Synchronization delivers each access revision as part of BiotSpec. Before it
acknowledges synchronization, the node closes every stream, because each one
belonged to the previous connection and its owner has already closed. Streams are
opened only by the server, so no node-side admission request exists; the server
is the only place policy is read.

The server captures one complete assignment snapshot, then sends bounded items
between begin and end. The node stages them under the connection ID and commits
the complete set only after matching count and end. Duplicate Biot IDs or a
truncated transfer cannot turn a partial list into authoritative absence.
The set excludes destroyed Biots whose final cleanup the server has recorded.
Interrupted staging is discarded; it does not replace accepted local intent.
The node then applies access revisions and hands required controller starts to
the starter before acknowledging synchronization. Controller startup failures retain
their bounded retry there; they cannot keep managed access from synchronizing.
The receiver bounds staged count and bytes by node capacity and the per-spec
limit. Incremental desired messages follow the snapshot and cannot interleave
with its staged items.

After receiving the complete BiotSpec set, the node compares it with its local
allocations and reports those whose recorded Biot ID is absent from the set.
The server adds the current connection ID and receipt time and stores them in
NodeObservation. `NodeView.orphans` and the structured server log show them.
Orphans consume local resources but are never automatically adopted or deleted.

The assigned node resolves an Environment atomically under its Environment ID.
It reports the resulting manifest; retry returns the same locally persisted
resolution. A different manifest for an already resolved ID is corruption. The
server stores the report but sends no canonical-resolution acknowledgement.

The connection is the sole ordered writer for node control messages. That order
does not prove which policy authorized a queued request. Each `open_stream`
carries the connection ID and revision from admission. The node admits it only
into the matching current group. Advancing to `r+1` ends all older streams and
prevents delayed requests for `r` from joining the new group.
Losing control closes every stream within the heartbeat loss timeout.
Containers and local reconciliation continue from the last accepted intent.
Host inspection, effects, and database work use supervised workers with finite
deadlines. They never block the process that enforces heartbeat loss or closes
stream groups. Inspection timeouts produce unknown facts, not inferred absence.
Request pairs (`diagnostic`, `runtime_logs`, `deliver_secret`, `remove_secret`,
`list_secrets`, and fetch credential delivery and removal) share one pattern.
The server holds the caller until a reply
or deadline. It releases pending state on timeout or disconnect and ignores
late replies.
Secret requests also follow the queue rules under
[Delivery and handling](#delivery-and-handling); their local deadline starts on receipt.

Each protocol version bounds a single BiotSpec's encoded size. Input validation
rejects selections that exceed it, including URL lengths and layer counts.
Startup rejects frame limits smaller than that bound plus framing overhead or
the allowed secret payload. Assignment snapshots use multiple bounded frames,
so every accepted selection and assigned Biot set can be delivered.
Codecs reject oversized lengths before allocating and close on malformed messages.
Their errors and crash reports follow the shared
[sensitive-value handling rules](#delivery-and-handling).

## 7. Environment artifact contract

Layers are Nix modules evaluated together with one pinned base package set and
the assigned node's platform. Use ordinary imports, typed options, defaults, and
source diagnostics rather than another merge language in Elixir.
Reuse existing Nix modules within this build boundary when they fit. Biot owns
container lifecycle, and the bundle owns service configuration. A second tool
must not start another environment manager or service lifecycle beside them.
A repository's own Nix configuration enters only as a layer, selected and pinned
like any other. The build never reads the Biot's working checkout.

Initial author-facing schema:

```nix
{ pkgs, ... }: {
  biot.packages = [ pkgs.git pkgs.nodejs pkgs.vim ];
  biot.environment.EDITOR = "vim";
  biot.shell = pkgs.zsh;
  biot.files."example/settings".text = "mode = development";
  biot.services.web = {
    command = [ "${pkgs.nodejs}/bin/node" "server.js" ];
    directory = { root = "checkout"; path = "."; };
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
  rootfs: StorePath
  entrypoint: StorePath
  shell_entrypoint: StorePath
  environment_file: StorePath
  config_root: StorePath
```

All paths are parsed references within the retained closure. BiotController sees
only an Artifact ID; the environment and host implementation interpret the
bundle. The allocation's private store is mounted read-only.
Checkout, home, and service data are private writable mounts.
Nix builds the immutable root filesystem, including ordinary interpreter paths
such as `/bin/sh` and `/usr/bin/env`, required system files, and mount points.
The host supplies namespaces and allocation mounts; it does not assemble a
parallel software filesystem. Host-generated network files overlay their
declared mount points. Runtime Nix installation into a writable store is deferred.

Service directories select `root: checkout | service_data` and a safe relative
`path`, defaulting to `{root: checkout, path: "."}`. `service_data` resolves
under `/biot/service-data`; `checkout` resolves under `/biot/checkout`.
The schema rejects absolute paths and paths that escape the selected root.

The container runs `entrypoint`, which starts the service runner. The runner
includes the reserved program `biot-agent` with `restart = always`;
`biot.services` rejects that name. The agent launches only `shell_entrypoint`
for shell requests.
The runner applies bounded backoff and an attempt limit to service restart
policies, including the agent. Exhaustion leaves that service failed and writes
a diagnostic to runtime logs. These limits are separate from container retries;
a service restart loop must not repeatedly restart the whole Biot.

Nix generates each service entry and `shell_entrypoint` using the
[runtime secret launch rules](#runtime-secrets).

`shell_entrypoint` changes to `/biot/checkout` and runs its arguments or
`biot.shell`, which defaults to bash. Both service and shell entries run as the
container user. The node captures runner output under the
[runtime log contract](#diagnostics-and-runtime-output).

### Private Nix execution and shared cache

Each allocation owns its Nix store, database, configuration, roots, and scratch.
The physical storage lives under its private root; the logical store path stays
`/nix/store` inside both builder and runtime. Keeping that path preserves binary
cache compatibility. A separate store directory alone is not filesystem isolation.

The node boots a disposable builder from the current release's pinned image containing Nix.
That image does not depend on the user's environment artifact. Evaluation, source pinning,
builds, and store maintenance run inside that worker. It has its own filesystem,
user and process isolation, and only explicit mounts: its private Nix storage,
staged inputs, and scratch. It cannot read the node journal, node credentials,
host filesystem, runtime secrets, or another allocation. It does not mount the
runtime's writable checkout, home, service data, or agent socket.
The worker uses the allocation's UID range and a separate isolated network,
with the same cross-biot isolation required for runtimes.

The node stages an immutable copy of its current release's build support. Resolution pins source inputs and the assigned platform.
Trusted pinning code resolves source selectors in the fetch phase. A separate
user build worker evaluates layers against the pinned manifest. Resolution is
atomic and retained under the Environment ID. User evaluation uses `--pure-eval`
with content-addressed staged inputs; moving refs are resolved separately.
Filesystem isolation provides confidentiality even when user Nix attempts an
absolute-path read.

Repository cloning and selector resolution accept only parsed HTTPS URLs. All
Biot-managed Git calls use `GIT_ALLOW_PROTOCOL=https`, disable inherited Git
configuration, credential helpers, prompts, and submodule recursion. Calls use a
clean environment, an empty trusted Git template, and fixed Git configuration.
The [source credential contract](#source-credentials) governs authenticated fetching.
Redirects must also remain HTTPS. Nix starts with an empty `NIX_PATH` and
controlled configuration and environment. These rules also cover source pinning;
user expressions cannot invoke a credential-bearing fetch helper.
User build tools execute only within their worker's isolation boundary.

Builds use Nix's build sandbox inside the worker. The supported Linux host setup
must demonstrate that nested isolation works; it cannot silently disable it.
The node never evaluates user layers as its own host process. A runtime mounts
only its own `/nix/store`, read-only, with no daemon socket or `/nix/var`.

A shared binary cache supplies trusted build results to each private store.
Cache misses build privately. Biots can read the cache but cannot publish to it,
change its trust keys, or upload private outputs automatically. The worker
verifies substitutes using operator-configured trusted keys. The node retains
installed and in-use closures through roots in the private store. Garbage
collection and store writes use the same single-worker ownership rule.

This duplicates unpacked dependencies across biots. The cache reduces downloads
and builds, but does not deduplicate private store storage. Unsupported required
isolation rejects node startup.

Worker CPU and memory limits, private store and scratch quotas, and a maximum
worker count are a v2 plan. They come after the UI has landed and the operator
has run the system for a while. When they arrive, the host must confirm they
work on the supported rootless setup, and an unenforceable limit rejects node
startup. Until then, one biot's build can consume the node's build resources;
the trusted group is the bound.

Adding a service option should change the Nix schema and generated runner
configuration without changing Desired, node messages, or reconciliation. Prove
the artifact and mount arrangement with one useful stateful environment before
expanding the schema.

## 8. Process ownership and operational limits

The implementation chooses the supervision tree from these ownership boundaries:

| Resource | Owner and contract |
| --- | --- |
| Biot actions, timers, and controller population | [Node recovery](#imperative-shell-and-crash-recovery) |
| Client connections and server stream sockets | [Session owners](#session-owners-and-admission) |
| Node stream groups | [Admission and revision changes](#session-owners-and-admission) |
| Build processes and private store writes | [Worker cancellation](#imperative-shell-and-crash-recovery) and [Nix isolation](#private-nix-execution-and-shared-cache) |
| Node connection membership and heartbeat deadlines | [Control transport](#6-connection-and-transport-boundaries) |

The SSH daemon is a child of the server supervision tree; the agent belongs
to the bundle's service runner. Registries use opaque IDs, never dynamically
created atoms. Expected build and configuration failures are values, not
supervisor restart signals.

Operator configuration bounds containers, streams per node and per biot,
session and credential lifetimes, buffers, assigned biots, and logs. The secret
size limit is a protocol constant shared by both releases. Build concurrency
and scratch growth bounds are v2. Disk exhaustion is reported. There is no
fair-share scheduler, billing, capacity reservation, or tamper-evident audit
system. The [diagnostic contract](#diagnostics-and-runtime-output) defines capture bounds.
Unguessable tokens do not replace request, buffer, or resource bounds.

In the first slice, disk exhaustion is a typed allocation, initialization, or
build failure with a diagnostic. Proactive disk-pressure health and alerting
belong to the operator's host monitoring until observed use establishes a useful
node-level product status.

Database loss and node storage loss are outside ordinary recovery. Surviving
files may be exported manually with coordination quiesced. Unknown resources are
not automatically adopted or deleted. Node retirement is not represented as disk
erasure; abandonment records that data may remain.

### Deployment contract

Two Mix releases exist: `server` and `node`. A getting-started guide belongs in a
separate document; this contract lists what that guide must cover.
The node release supplies trusted build support and dependency pins.
Builders load those files directly from the release.

| Server setting | Meaning |
| --- | --- |
| `PHX_HOST`, `PORT`, `SECRET_KEY_BASE` | Control host name and HTTP listener |
| `BIOT_SERVER_PUBLICATION_DOMAIN` | Suffix of every preview hostname; `PHX_HOST` must not be under it |
| `BIOT_OIDC_ISSUER`, `BIOT_OIDC_CLIENT_ID`, `BIOT_OIDC_CLIENT_SECRET` | The one login provider |
| `BIOT_SESSION_LIFETIME_HOURS`, `BIOT_CREDENTIAL_MAX_LIFETIME_DAYS` | Absolute lifetimes |
| `BIOT_SSH_PORT`, `BIOT_SSH_HOST_KEY_FILE`, `BIOT_SSH_ADVERTISED_HOST` | The SSH daemon and what `DeploymentView` reports |
| `BIOT_CONTROL_PORT`, `BIOT_CONTROL_CERTFILE`, `BIOT_CONTROL_KEYFILE`, `BIOT_CONTROL_CACERTFILE` | Node control and stream listener |
| `BIOT_NODE_REGISTRATIONS` | Operator enrollment file |
| `BIOT_DISABLED_PRINCIPALS` | Operator file listing disabled issuer/subject identities |
| `BIOT_TRUSTED_EDGE_PEERS` | Edge addresses allowed to supply forwarded metadata |
| `BIOT_AUTH_CHECK_INTERVAL_MS` | Maximum interval between live proof validity checks |
| `BIOT_STREAM_OPEN_TIMEOUT_MS` | How long a stream may take to open |

Node settings keep their existing `BIOT_NODE_*` names and add
`BIOT_NODE_MAX_STREAMS` and `BIOT_NODE_MAX_STREAMS_PER_BIOT`. The node also configures
the trusted builder image and binary cache URLs and keys. Worker CPU and memory
limits, storage quotas, and a maximum worker count are v2 settings; see
[Private Nix execution and shared cache](#private-nix-execution-and-shared-cache).
The getting-started guide names the supported Linux mechanisms and verifies
their enforcement. Certificate
tooling preserves the operator's CA certificate and protected private key so
it can issue and renew leaf certificates. The operator can also supply an
existing CA; the CA private key is never deployed to a node. `mix biot.certs`
creates the authority once and issues or renews each leaf; renewal reuses the
leaf key, so a peer's identity survives it. Reloading registrations permits peer-key replacement
under the same Node ID. The SSH host-key file may contain several OpenSSH host
keys, at most one of each type; the operator generates the file.

The edge reverse proxy has one job that never changes: terminate TLS for the
control host and for `*.<publication domain>` with a wildcard certificate, and
forward both to the server's HTTP port. It must pass `Host` unchanged, replace
client forwarding headers with its own values, support WebSocket upgrades, and not
buffer streamed responses. SSH clients reach the server's SSH port directly; it
is not behind the edge. Nodes reach the control port directly.

## 9. Walkthroughs

### Create to running

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

Node control ingestion:
  persist the complete BiotSpec
  apply its access revision at the stream boundary and send access_applied
  ensure the BiotController exists and notify it

Node BiotController:
  inspect and derive NodeState(no allocation)
  allocate UID range, data root, and network
  initialize the checkout once and inspect its completion marker
  boot the allocation's isolated worker with private Nix storage and staged inputs
  resolve e_1 with pinned sources and platform; report its canonical Manifest
  prepare its EnvironmentBundle using current build support and trusted cache substitutes or private builds
  retain its closure in the private store and stop the worker
  install e_1 against b_1's allocation
  create the container under b_1's stable name; inspect its native ID c_1
  inspect after each effect and report Observation(connection, revision=1)

Server report transaction:
  require the current registration, assignment, and report revision
  store the latest Observation
  mark op_1 succeeded when e_1 is installed and c_1 is running

Query:
  project BiotView from Desired, Observation, Node, and op_1
```

If an HTTP response or wakeup is lost, the Biot and Operation already exist and
periodic delivery or synchronization redelivers the BiotSpec. If the node process dies, its replacement
loads that spec and allocation metadata, inspects resources, and
continues from the first unmet condition. It never restarts the sequence from
the clone step merely because process memory was lost.

With initial secrets, the client instead requests `initial_state=stopped`.
The node prepares and installs the environment but does not start a container.
After the create Operation succeeds, the client delivers each secret and awaits
success. It then requests start with the current desired revision and waits for
that Operation. A delivery failure leaves a prepared, stopped biot for retry.

With private sources, the client also selects stopped creation. It waits for
allocation, delivers each scoped fetch credential, then waits for preparation.
The trusted fetch phase authenticates checkout and layer reads. Runtime secrets
arrive only after preparation, before start. Missing fetch credentials keep the
create Operation working and show the source needing access.

### Publish to preview

```text
Owner:
  PUT /api/biots/b_1/publications/3000
  PUT /api/biots/b_1/grants/view/3000/<alice>

Server transactions:
  allocate Publication(b_1, 3000, hostname h, active), or reactivate its existing row
  return https://h.<domain>
  insert ViewGrant; access revision unchanged

Alice's browser:
  GET https://h.<domain>/ with no preview cookie
  -> handoff cookie, redirect to control /preview/authorize
  -> control session (login if needed), PreviewHandoff.begin checks may_view?
  -> redirect to https://h.<domain>/__biot/callback?code=...
  -> PreviewHandoff.finish, preview cookie, redirect to /

Proxy, for each request:
  Sessions.preview(h, cookie) -> authentication linked to control login
  Access.open_preview(authentication, h): register, check proof and may_view? at revision r
  Streams.open(node, b_1, r, port(3000))
  node: admit into group(connection, r), open a verified agent connection
  node: {"target":"port","port":3000} -> {"ok":true}; attach(connection, stream) to server
  proxy writes the rewritten request, streams the response, closes the stream

Owner revokes Alice:
  DELETE /api/biots/b_1/grants/view/3000/<alice>
  commit revision r+1, close owners for b_1, send BiotSpec(r+1)
  node retires b_1's old stream group, rejects late opens for r, reports applied r+1
  Alice's next request: 403; her open WebSocket is already closed
```

### Shell over SSH

```text
Alice:
  biot ssh-key add ~/.ssh/id_ed25519.pub
  biot ssh checkout-flow [--identity ~/.ssh/id_ed25519]
    -> ssh -o StrictHostKeyChecking=yes
          -o UserKnownHostsFile=<temporary advertised known_hosts>
          -o GlobalKnownHostsFile=/dev/null
          -p 2222 <b_1>@biot.example
  (refuses if DeploymentView advertises no host key)

Server ssh daemon:
  key callback: KeyCallback delegates SshKeys.authenticate(key) -> Authentication(alice, key k)
  session channel with pty-req and shell:
    register owner under biot, principal, and SSH key
    recheck key and principal; may_shell?(alice, b_1, shell_grants) at revision r
    Streams.open(node, b_1, r, shell(term, cols, rows, none))
  node: admit into group(connection, r), open a verified agent connection
  node: shell target -> PTY running shell_entrypoint; attach(connection, stream)
  shell frames flow on the dedicated connection; window-change becomes a resize frame
  agent drains output, sends exit frame; server forwards output then channel exit status
```

## 10. Required evidence

Pure unit tests cover desired transitions, authorization, affected access scope,
the four reconciliation decisions, retry classification, query projection, the
agent protocol codec, and header rewriting. Database and process rules use
integration tests with real OTP trees, temporary SQLite databases, real worker
termination, and small protocol peers. Host tests use temporary owned resources
and the relevant real host facilities, including a real agent in a real
container.

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
| Nix attempts to read host or neighboring files | Evaluation cannot read node credentials, journal, or another allocation; private reads never reach a shared store |
| Private store and cache | A real cached build and a cache miss run in an isolated worker; the runtime executes both closures without a daemon mount |
| Worker cancellation | The whole worker ends, including its daemon; another writer waits for inspected absence; installed closures remain usable |
| Controller or node restart during a build | Recovery cancels the whole worker before retrying; completed outputs remain reusable; matching runtime containers stay running |
| Worker resource limits (v2) | CPU and memory limits and storage quotas work on the supported Linux host; one worker cannot exhaust unbounded node resources |
| Managed source fetching | Local paths, `file://`, `ext::`, SSH, protocol-changing redirects, inherited helpers, and submodule recursion cannot bypass HTTPS-only fetching |
| Service exits while its supervisor runs | Lifecycle success remains accurate; an owner or shell collaborator can retrieve useful bounded runtime logs |
| Desired-running container repeatedly exits | Retries back off and eventually require owner action |
| Controller restarts during backoff or after exhaustion | Retry counts and terminal failure survive; observations continue while effects stay blocked |
| Automatic attempt fails before later success | One Operation stays working through retries, then succeeds |
| Stop with unreadable or lost data | The owned container is retired before data or environment readiness can block |
| Unreadable obsolete prepared root | The desired artifact can still be inspected and used; cleanup waits for its own required facts |
| Node upgrade followed by rebuild | Intact installations stay unchanged until rebuild; preparation uses current build support without retaining older toolchains |
| Container create reply is lost | Stable name resolves the native ID; ownership labels prevent adoption or deletion of a foreign container |
| Unsupported node protocol | Handshake rejects before synchronization |
| Startup enrollment, reload, and peer-key replacement | Configured peer authenticates; old peer is rejected; IDs and allocations stay; omission disables; terminal identity cannot return |
| Abandoned node | Pending Operations fail `node_abandoned`; destroy releases the name and fails honestly; reconnect is rejected |
| Cross-biot environment selection or artifact release | Database ownership constraint or host ownership check rejects it |
| Diagnostic fetch stalls or exceeds its limit | Caller completes within its deadline; response stays bounded |
| Server database omits a node allocation | NodeObservation and NodeView expose the orphan without adopting or deleting it |
| OIDC login, logout, expiry | First login creates an enabled principal; logout and expiry invalidate cookies and close LiveViews, terminals, and preview WebSockets |
| Lost logout notification | Proof validity checks close idle connections within the configured bound; later LiveView events fail authentication |
| Preview login lifetime | Every preview references its originating control login; handoff cannot extend expiry or succeed after parent logout |
| Operator disables a principal | Provider login, existing tokens, keys, and live access fail; ownership stays; re-enabling restores no old proof |
| Revoked or expired credential | Next API request is 401; the clear token appears nowhere in the database |
| Credential issuance | Only a current control-session proof can issue a token; a bearer token cannot mint another |
| Preview handoff misuse | Reused code, wrong host, missing or wrong challenge cookie, and expired code are all rejected |
| Preview request policy | Every request reads the grant; revocation returns 403 and closes the open WebSocket |
| Client preview | Existing bearer credential obeys per-port policy; Biot strips its header and preserves application Authorization |
| Preview WebSocket Origin | Cookie-based upgrades from sibling origins or without Origin fail; same-origin upgrades reach the byte tunnel |
| Preview header boundary | Biot cookies never reach the application; its `Set-Cookie` for a Biot cookie is dropped; identity and forwarding headers are replaced; control characters cannot inject headers |
| Forwarded metadata trust | Only configured edge peers supply client metadata; client-supplied forwarding chains cannot become trusted values |
| Caller-specific query projection | View-only users see only granted active ports; secret names and full grant lists remain owner-only |
| Preview failure pages | Unpublished, forbidden, not running, and not listening render distinct responses |
| Stream attach | Unknown stream ID, wrong node, old connection ID, or wrong peer identity is rejected; the registered target determines framing |
| Admission races revocation | Registered owner is denied or subsequently closed |
| Old admission arrives after revision application | Node rejects the old revision; the server rereads proof and policy before any retry |
| Agent socket replaced by a symlink | Neighboring or unrelated peer UID is rejected before a target is sent; the allocation's mapped UID is accepted |
| Agent sends malformed or oversized input | Request and reply lines and shell frames stay bounded; malformed streams close without payload logs |
| Revoke one user while another is connected | All node streams close; still-authorized users reconnect |
| Node applies a higher access revision | Stream boundary closes every old stream before access_applied, independently of blocked lifecycle work |
| Control link loss during blocked host or database work | Streams close within the heartbeat bound; local lifecycle work can continue |
| Server dies after withdrawal commit | Revision sweep eventually resends closure work |
| Node disconnects during revocation | Pending revision clears after timeout or synchronized reconnect |
| Terminal session | Resize reaches the PTY; the exit status reaches the browser; closing the browser ends the shell process group |
| Shell sends final output before exit | Browser and SSH receive all output before status on one connection; missing exit frames never imply success |
| SSH daemon | Forwarding requests fail; sftp is absent; a second channel after revocation is denied; key removal closes the connection |
| Secret delivery | Node offline returns `temporarily_unavailable`; files are readable in the container; values appear in newly launched services and shells |
| Create with initial secrets | No container starts before every delivery succeeds; failed or uncertain delivery leaves the biot stopped |
| Secret acknowledgement is lost | Exposure marker was committed before send and remains true; retry replaces the same file |
| Secret removal then a new shell or service restart | Removed values are absent from new environments even when the supervisor and agent predate removal |
| Secret mutation races start or destruction | The allocation owner serializes effects; no write recreates a removed allocation or runs after its range is released |
| Secret handling fails | Values are absent from server storage, CLI arguments, request logs, codec errors, and OTP crash reports |
| Secret listing while node is offline | Owner sees unavailable; the server does not invent current state or retain per-name history |
| Private checkout and layer sources | Credentials arrive after allocation and before preparation; trusted fetches succeed; user evaluation and runtime never receive their values |
| Largest accepted selection and assignment | Bounded synchronization delivers the full set; interrupted staging cannot remove accepted intent |
| Intent saved before controller startup fails | Starter or repeated delivery starts the missing controller; normal crashes remain the supervisor's responsibility |
| Completed destruction followed by disconnect | Controller exits; durable final report reaches the server after reconnect without a permanent controller |
| Ownership prerequisite fails | Dependent management stops and recovers ownership before more actions; matching runtime remains intact |
| Diagnostic reader restarts during large output | Stored diagnostic IDs remain usable and capture files stay within their byte bounds |
| Runtime filesystem and service directories | Ordinary shell interpreter paths work; checkout and service-data directories resolve explicitly |
| Unpublish and republish | Same hostname returns without old view grants |
| Preview sibling-origin requests | Application cannot acquire or replace control authority |
| Unpublished sibling listener | Traffic from one biot's container to another's address fails |
| Stateful composed service | Replacement preserves data and environment details stay out of BiotController |

Release evidence is one real deployment: the server and node releases on two
machines, a real OIDC provider, a real edge with a wildcard certificate, a private
repository and layer fetched with scoped credentials, a published port opened in a browser as
a second user, a browser terminal, and an SSH session. Record the run in the
getting-started guide; test images with local repositories do not replace it.

## 11. Why the model stops here

Biot protects a trusted group from accidental cross-biot access, unauthorized
managed access, hostile preview origins, and routine process or network failures.
Storage loss, determined container escape, and highly available control remain
outside its scope.

### Node administration is operator configuration

[Operator enrollment](#operator-enrollment) uses one configuration source with
explicit reload. This permits renewal and access changes without a separate
enrollment service or administration API. Stable node identity preserves
allocations and history when peer keys change.

### The biot has one door

The [agent connection](#agent-connection) avoids container address discovery,
host-port allocation, and dependence on a particular rootless network helper.
It costs one Go agent per runtime and makes shells depend on that agent.
The same connection boundary serves previews, terminals, and SSH.

### Streams are connections rather than a multiplexed channel

[Dedicated connections](#streams) give each stream independent TCP flow control.
They cost one TLS handshake per preview request or shell, but avoid window
accounting and shared-channel scheduling in Biot. Connection pooling can remain
a local transport change if latency later warrants it.

### Policy is read on the server only

[Server admission](#session-owners-and-admission) gives every access surface one
policy authority and closure mechanism. It routes terminal traffic through the
server and requires clients to reach its SSH port. Node-hosted entry points
would add policy requests and endpoints for users to discover.

### Every shell has a PTY

The [agent protocol](#agent-protocol) combines stdout and stderr in one PTY stream.
This deliberately excludes `scp`, `rsync`, sftp, and Git over inbound SSH.
Users work through tools inside the Biot and its published ports.

### Secrets never rest on the server

The [secret contract](#secrets) accepts uncertain delivery and an unavailable list
when the node is offline. This avoids a server file mirror, per-name history,
queued plaintext, and encryption-key management. Its exposure marker can overstate
exposure, but never promises that removal erased a workload's copies.

### Credential integrations follow the agent

[Source credentials](#source-credentials) solve private fetching before a runtime
exists. General GitHub token issuance, API key proxying, and commit signing remain
deferred. Those runtime integrations can use the private node-agent boundary
without making source fetching depend on a general mediation protocol.

### Sessions are rows rather than signed cookies

[Session proofs](#authentication-surfaces) cost database lookups, including the
preview's parent login. In exchange, one browser logout can end authority across
preview hosts. Live owners enforce that decision on existing connections;
a database deletion alone cannot close a socket.

### Revocation is bounded rather than transaction-linearizable

[Admission ordering](#session-owners-and-admission) allows a stream racing with
revocation to finish opening and then close. This avoids transaction barriers,
durable per-stream obligations, and a global admission coordinator.
The control-loss and validity-check deadlines bound how long stale access lasts.

### Host work converges rather than executing exactly once

[Recovery](#imperative-shell-and-crash-recovery) preserves matching runtime containers
but cancels surviving build workers. This loses unfinished computation and avoids
worker adoption and saved command state. Completed outputs and cache substitutes
reduce repeated work; they cannot recover every interrupted build step.

### Each Biot has its own controller

[BiotController](#imperative-shell-and-crash-recovery) keeps each Biot's lifecycle
work local. OTP supervision restarts existing children; a starter handles durable
intent whose child never started. This avoids a second lifecycle loop while
allowing completed destruction to release its controller.

### Offline control closes access, not local progress

A connection outage does not invalidate the last accepted execution intent.
[Offline reconciliation](#pure-decision-core) keeps resource recovery independent
of server reachability. Managed access still depends on the server, and the UI
shows stale observations until reporting resumes.

### Reconciliation receives one derived resource view

[NodeState](#show-me-node-ownership) resolves journal and host facts at one boundary.
The pure core can reason about `lost`, `uninitialized`, and `unknown` directly.
This gives up independent access to every bookkeeping detail and keeps storage
representation out of lifecycle decisions.

### Restart is composed from simpler lifecycle changes

[Stop followed by start](#desired-execution) needs no restart token or second
generation counter. The tradeoff is two Operations and no atomic restart request.

### Retries use resource identity and revisions

[Application results](#lifecycle-and-policy-results) let clients recover through
resource IDs and current revisions. Clients may need to reload after a lost
reply; the server does not keep a permanent receipt for every request.

### Stable URLs are allocated once

[Publication rows](#show-me-the-server-state) retain their hostname while inactive.
This keeps a small amount of history and avoids a permanent hostname-derivation
key with its own backup and rotation rules.

### Policy progress is per assigned node

[Access revisions](#session-owners-and-admission) avoid per-stream durable closure
records. The cost is visible: withdrawing a grant or unpublishing closes every
stream on that Biot, including the owner's terminal. Authorized users reconnect.
Narrower closure would need matching scopes in admission and recovery.

### Environment resolution has one owner

[Node-owned resolution](#6-connection-and-transport-boundaries) avoids a distributed
agreement step before preparation. Fixed assignment makes that reasonable;
migration or competing resolution authorities would change the premise.
A manifest freezes sources and platform. Current release support builds them,
so old manifests do not require retaining old generators or toolchains.

### Environments remain per biot

[Private stores](#private-nix-execution-and-shared-cache) cost repeated evaluation
and duplicate unpacked dependencies. They isolate user Nix and keep one Biot's
store changes from affecting another. The shared cache reduces downloads and
builds without exposing private outputs or writable store state.

### Lost nodes are abandoned rather than falsely cleaned

[Abandonment](#node-status) lets owners release names without claiming missing
data were erased. It preserves the distinction between confirmed destruction
and resources that may still exist on an unreachable machine.

### Server purity stops at transactional state

[Application transactions](#lifecycle-and-policy-results) retain capacity,
uniqueness, and mutation ordering. Extracting a pure write plan would duplicate
the database snapshot and its constraints. Pure rules stay separate where they
do not depend on that transaction.

### Abstractions follow implementations

Concrete modules and explicit ownership keep the initial system understandable.
A shared interface earns its place when another implementation needs it.
Changes to one environment option, transport adapter, or credential integration
should remain within that boundary.
