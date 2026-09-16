# Repository map

## Layout

- `apps/biot_protocol` owns shared parsed values and wire codecs.
- `apps/biot_server` owns server modules, queries, policy, and the server database.
- `apps/biot_web` owns the Phoenix HTTP API, the LiveView UI, and the browser terminal.
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

- `Message.*` defines the protocol message structs. Version 1 includes the five secret and fetch-credential requests—`DeliverSecret`, `RemoveSecret`, `ListSecrets`, `DeliverFetchCredential`, and `RemoveFetchCredential`—and the three results `SecretResult`, `SecretListResult`, and `FetchCredentialResult`, alongside diagnostics and runtime logs. The stream messages are `Attach` and `Attached` in the handshake phase and `OpenStream` and `StreamFailed` in the main phase, and `Reject` adds `:unknown_stream`.
- `SecretName`, `SecretValue`, and `AuthorizationValue` are parsed boundary values. Secret and authorization values redact themselves and expose bytes only through `reveal/1`; a bare value exists only in `parse/1` and the single file write that publishes it.
- `SecretOutcome` owns one union and codec for `:ok`, `:no_allocation`, and `{:failure, :write_failed | :unavailable}`. The listing result uses the same codec with `{:ok, [SecretName]}`.
- Each `Message.*` module declares its fields and codecs through `Biot.Protocol.Message`. `Wire`
  iterates those declarations for strict encoding and decoding, phase checks, message bounds, and
  the version 1 table. It enforces the 256 KiB `BiotSpec` bound and the
  `Limits.max_secret_value_bytes/1` bound. `Wire.min_frame_bytes/1` includes the largest
  base64-encoded secret delivery envelope and the `OpenStream` envelope near the agent line bound,
  and `check_frame_limit!/1` is checked at boot by both applications.
- `Frame` encodes and incrementally decodes length-prefixed frames. `take/2` takes exactly one frame and leaves every byte after it untouched.
- `Version` selects the highest protocol version shared by both peers.
- `Liveness` matches heartbeat responses.
- `Platform` represents supported Linux host platforms.
- `PeerIdentity` computes certificate public-key fingerprints.
- `Certificates` and `mix biot.certs` manage deployment certificates. `authority` creates and
  preserves the CA certificate and mode-0600 private key; `server` and `node` issue or renew leaves
  from that authority without changing their keys or fingerprints.
- `OrphanedAllocation` represents node allocations absent from server intent.
- `Limits` owns the versioned spec bound and shared component limits. Version 1 allows a 256 KiB
  spec, a 64 KiB secret or authorization value, a 2,048-byte repository URL, a 256-byte source ref,
  and 16 layers. `Limits.max_agent_line_bytes/0` is the agent's request-line bound, including the
  trailing newline.
- `StreamId` is an opaque canonical UUID that identifies one stream a node holds.
- `StreamTarget` is the one target encoder. It encodes either a port or a shell request, and its encoded form is the agent's own request line.
- `ShellRequest` parses one shell's terminal, initial size, and optional command. A nil command runs the bundle's shell entry as a login shell; a list runs through that same entry. It refuses an empty term, an out-of-range or non-integer size, an empty or non-list command, a NUL byte, and text that is not valid UTF-8.
- `StreamFailure` owns the closed node refusal reasons: `unknown_biot`, `stale_access`, `agent_unreachable`, `port_not_listening`, and `too_many_streams`.
- `AgentReply` parses the agent's one reply line into `:ok` or `{:error, :invalid_request | :connection_refused}`.
- `ShellFrame` is the shared shell frame codec. `encode/1`, `decode/2`, and `reframe/2` use one direction rule: data flows both ways, resize only toward the agent, and exit only toward the server. `reframe/2` stops after an exit frame and rejects bytes after it.

### Value modules

- **Identifiers:** `CanonicalUuid` parses canonical UUID strings. Eleven opaque UUID identity
  modules use `UuidValue`, which supplies their common struct, parser, generator, and string form.
- **Names:** `BiotName` is a lowercase DNS label and rejects UUID-shaped names, so clients can
  distinguish a name from a `BiotId` without a lookup.
- **Sources:** `RepositorySource` represents a credential-free Git repository URL and derives its normalized `origin/1` for credential attribution.
- **Sources:** `SourceSelector` represents an unpinned source and its ref.
- **Sources:** `PinnedSource` represents a source with a commit revision and Nix NAR hash.
- **Environment:** `EnvironmentSelection` represents the base package set and ordered layer
  sources for an environment.
- **Environment:** `Manifest` freezes the platform and resolved sources and carries their content
  digest.
- **Environment:** `Digest` represents a raw SHA-256 digest with a named encoding. `Digest.compute/2` serializes with a named encoding; `Digest.sha256/1` returns the plain SHA-256 of bytes.
- **Execution:** `Desired` represents execution intent and provides `transition/2`.
- **Execution:** `BiotSpec` contains execution and access intent for an assigned node.
- **Execution:** `ExecutionSpec` contains complete server-owned execution intent.
- **Execution:** `ExecutionReport` contains node-supplied execution facts, including `waiting_for` when a fetch needs an operator credential.
- **Execution:** `Failure` represents a bounded description of a failed lifecycle action.
  Its stages include `node` and `release_environment`; its codes include `node_abandoned`,
  `invalid_configuration`, and `ownership_mismatch`.
- **Execution:** `ContainerState` represents the observed state of a container.
- **Identifiers:** `ConnectionId` identifies an authenticated node connection.
- **Identifiers:** `IncarnationId` is Podman's full 64-hex native container ID. The node parses it
  from inspection and never generates it.
- **Other parsed values:** `Hostname` represents a lowercase DNS label.
- **Other parsed values:** `Port` represents a valid user-facing TCP port.
- **Other parsed values:** `SshPublicKey` represents one OpenSSH public key line. It splits the line on any whitespace and parses the key type and blob through OTP `ssh_file`, so a comment, including one with spaces, is accepted and dropped from the stored canonical line. It computes the `SHA256:` fingerprint OpenSSH prints.
- **Other parsed values:** `SameOriginPath` represents an absolute path with an optional query. It rejects a scheme, a host, a fragment, whitespace, a backslash, and a leading double slash.

`RepositorySource`, `SourceSelector`, and `EnvironmentSelection` enforce the shared limits. They
return `:repository_url_too_long`, `:source_ref_too_long`, and `:too_many_layers` for those bound
violations. `Choice.parse/2` owns parsing for closed atom sets, and `StrictMap.fetch_exact/2` owns
strict map shapes.

Parsed values share `parse/1`, which returns `{:ok, t} | {:error, atom}`.
Their `to_string/1` output round-trips through `parse/1`.
`ParsedList.parse/2` parses a list of values with a supplied parser. `ParsedList.parse_indexed/2` returns the first bad element's index with its reason.
`Failure`, `Manifest`, `EnvironmentSelection`, and `ContainerState` provide `encode/1` and `parse/1`.
Tests for this app are pure unit tests with StreamData property tests.
`test/test_helper.exs` holds the generators.
`test/control_protocol_test.exs` covers the version 1 runtime-log request pair and malformed result shapes, including the `:unknown_stream` reject reason.
`test/stream_protocol_test.exs` covers `StreamId`, `StreamTarget`, `ShellRequest`, `StreamFailure`, `AgentReply`, `Frame.take/2`, and the new messages through `Wire`. It fuzzes every parser and codec with random binaries and terms.
`test/shell_frame_test.exs` covers `ShellFrame` encode, decode, `reframe/2`, direction rules, payload bounds, partial frames, and the exit-last rule.
`test/identity_values_test.exs` covers `CredentialId`, `SshKeyId`, `SshPublicKey`, `SameOriginPath`, and `Digest.sha256/1`.

## apps/biot_server

### Layout

`Schema.*` are plain Ecto schemas with no changesets.
`Ecto.*` are custom types.
`ProtocolValue` stores any parsed protocol value as text.
The other custom types wrap protocol `encode/1` and `parse/1` functions.
`Principals` and `Nodes` own transactions.
`Principals` owns principal identity, the authenticated principal view, operator disabling, and
last-seen email lookup.
`Principals.require_enabled/2` is the one rule for a disabled principal, and every application boundary that accepts an `Actor` calls it.
`Principals.reload/0` applies the operator's disabled identity set.
`OperatorFile` owns reading an optional operator-managed JSON list.
`Principals.DisabledIdentities` and `Nodes.RegistrationLoader` parse their respective list entries.
`Principals.Startup` runs `reload/0` before the control listener and fails boot with a readable message on invalid configuration.
`Nodes.reload/0` is the one enrollment entry point.
`Nodes.Startup` calls it at boot and fails boot with a readable message on rejection.
Operators call it with `bin/server rpc "Biot.Server.Nodes.reload()"`.
It loads the enrollment file and runs the enrollment transaction.
After commit, it closes the session owners of every Biot whose access revision it bumped and notifies the browser readers of every Biot on a changed node, then closes planned control connections.
It sends no wake, because a reconnected node receives the new revisions in its snapshot.
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
`Actor` is the authenticated caller.
`CommandError` is the model's error union.
`CommandError` includes `destroyed` for lifecycle changes against a destroyed Biot.
`DomainName` parses the control host and publication domain and enforces that no preview hostname
can overlap the control host. `Login.Settings` parses the required HTTPS OIDC configuration once at
release boot.

### Application modules

- `Biots` handles `create`, `start`, `stop`, `update_environment`, and `destroy`. Its `after_commit/1` runs the `CommitEffects` fence after a committed change with the Biot as reader; a destroy also closes its owners, and a written-off node gets no wake.
- `BiotSpecs.build/1` builds the node-facing `BiotSpec` from the Biot and Environment rows. It reads no policy or lifecycle command code, so the control connection depends on it instead of on `Biots`.
- `Biots.Create`, `Biots.SelectEnvironment`, `Biots.Accepted`, `Biots.Unchanged`, and `Biots.CreationFingerprint` define lifecycle inputs, results, and fingerprints. `Create.initial_state` defaults to `:running`, and the fingerprint uses `:biot_creation_v2`.
- `Biots.Capacity.room?/2` admits creation, and `counts/2` projects capacity held on assigned nodes. Together they define which Biots still hold capacity.
- `Operations` owns operation queries.
- `Operations.Completion` provides pure completion evidence. `:create` and `:update_environment` use one clause set for each desired state.
- `Reports` handles node-facing ingestion through `observation`, `access_applied`, `resolution`, and `node_observation`. A stored `observation` or `access_applied` notifies the Biot's readers; `resolution` sends nothing because it is in no reader projection.
- `Queries.Biots.get/2` and `list/2` build owner and collaborator `BiotView` values. `Access.readable/2` supplies their single read rule. `PublicationView.visible/2` limits collaborator publications to their view grants.
- `Queries.BiotDetailView.get/2` adds the Biot's repository and selected `EnvironmentSelection` to that view for the overview.
- `Queries.AccessDisplayView.get/2` resolves the owner and every grant principal ID into `PrincipalView` values for the access panel.
- `Queries.Navigation.counts/1` returns the readable Biot count and the node count used by the application frame.
- `Queries.Nodes.list/1` and `Queries.NodeView` build the node inventory with capacity counts, live connections, and latest orphan reports.
- `Queries.Deployment.get/1` returns the publication and SSH settings in `DeploymentView`.
- `Queries.PrincipalView`, `Queries.BiotView`, `Queries.PublicationView`, and `Queries.OperationView` provide pure projections. `PrincipalView` projects the authenticated principal's ID and latest OIDC email and name. `BiotView` includes the actor's `role`, the row's `direct_secret_exposure_possible` column, and `waiting_for`. Creation sets the exposure column to `false`; observations supply the current wait.
- `Authorization` owns the `grants` and `role` types and the pure role and policy predicates.
- `NodeConnections` is a thin layer over `Control.Registry`, the one node membership table. The key is the node ID, the process is the control connection, and the value is the connection ID and state. Only the owning control process writes its entry, through `put/2` and `delete/1`. The entry leaves the Registry when that process exits. `current/1`, `connection_pid/1`, `ready/1`, and `ready_connection/1` skip an entry whose process is already dead.
- `NodeWake` provides one PubSub topic per node, plus `spec_changed/2` and `subscribe/1`.
- `BiotChange` provides one PubSub topic per Biot, plus `changed/1`, `subscribe/1`, and `unsubscribe/1`. A browser reader subscribes to the Biot its page shows and reloads its authorized projection on `{:biot_changed, biot_id}`.
- `CommitEffects` is the one post-commit fence: `enforce/1` takes a `%CommitEffects{owners:, wakes:, readers:}` struct, closes owners, wakes nodes, then notifies readers, in that order. It is the only caller of `BiotChange.changed/1`, so no reader notification can fire before a commit.
- `Delivery` owns the one delivery rule: the caller must own a non-destroyed Biot whose assigned node is ready, and it returns that node's live connection.
- `Secrets` delivers, removes, and lists runtime secrets. Delivery commits `direct_secret_exposure_possible` before sending, notifies the Biot's readers after that commit, and that historical marker is never cleared. `FetchCredentials` uses the same delivery rule but does not set the marker, queue work, or make a durable server write; its effect reaches readers with the next observation. `Queries.SecretView` projects the names returned by `list/2`.
- `ExpirySweep` is the one owner of the expiry sweep. It runs every `expiry_sweep_interval_ms`, reads the clock once, and calls `sweep_expired/1` on `Sessions`, `PreviewHandoff`, and `Credentials`. A nil interval disables the process, and `config/test.exs` sets nil so it does not start under the manual sandbox.

#### `Biot.Server.Publications`

`publish/3` allocates a random hostname for a new port or reactivates its retained
inactive row. A row has state `:active` or `:inactive`. Republish keeps the same
hostname. `unpublish/3` makes the row inactive and deletes that port's view grants.
`withdraw_all/2` deactivates every row and deletes every view grant during destroy.
`active?/3`, `active_by_hostname/2`, and `active_for/1` are the only reads of active publication rows.
`discover/2` returns active URLs allowed by the actor's role. Each mutation returns a
`Policy.Applied` result when it changes records, or a `Policy.Unchanged` result
when the requested policy already exists. Both result structs carry the Biot ID,
access revision, and `enforcement`.

#### `Biot.Server.Access`

`readable/2` builds one composable query for listings. Owners, shell-grant
holders, and view-grant holders match it. It must match
`Authorization.may_read?/3`, which decides one loaded Biot. `fetch_readable/2`
returns the Biot and the actor's role, or `not_found` or `forbidden`; it decides
with `may_read?/3`. `grants_for/2` is total over the requested IDs and returns an
entry for each one. `revoke_shell_grants/2` removes all shell grants during
destroy.

`view_authority/3` is the one preview view authority read. It returns the active
publication at a hostname, its Biot, and its node when `Authorization.may_view?/4`
allows the actor. Otherwise it returns `not_found` or `forbidden`. It takes the
caller's repo so the read runs inside the caller's transaction. `PreviewHandoff`
and preview admission both call it.

`open_preview/2` and `open_shell/3` are the model entry points for stream
admission. Each one passes a snapshot read to `Access.Admission.admit/3`, which
runs it in one transaction. `open_preview/2` first finds the Biot of the active
publication at the hostname, only to register under it. The preview snapshot then
checks these conditions in order:

1. The proof is accepted on that preview host.
2. `Validity.check/3` finds the proof live.
3. `view_authority/3` allows the actor.
4. The publication still belongs to the registered Biot.
5. The Biot is not destroyed, and its node is enabled.

The shell snapshot checks that the proof is accepted on `:shell` and is live,
that `may_shell?/3` allows the actor, and the same Biot and node conditions. Each
snapshot returns an `%Admission{}` with the node, the access revision, the stream
target, and the proof's live expiry. A disabled node gives `node_unavailable`.

`grant_shell/3` and `revoke_shell/3` manage Biot shell grants.
`grant_view/4` and `revoke_view/4` manage a principal's access to one published
port. `get_grants/2` returns the owner and explicit grants for the Biot. Mutation
results use `Policy.Applied` or `Policy.Unchanged`, with the same `enforcement`
field. Grants require known principals; view grants require an active publication
for the same Biot and port.

#### Session owners and admission

A session owner is the process that holds one admitted stream, such as a browser
preview or a shell. `Access.Admission` runs the owner protocol. `Access.Owners`
records which closes reach each owner.

`Admission.admit/3` runs in the owner process in this order:

1. It drops any close left in the mailbox by an earlier admission.
2. It registers the process in `Owners` under the Biot, the principal, and each
   proof key.
3. It reads the snapshot in one transaction, with a close check before and after
   the read.
4. It opens the stream with `Streams.open_until/5` before one deadline of
   `stream_open_timeout_ms`.
5. On success, it monitors the control connection and starts the expiry timer.
   Then it checks for a close once more.

Registration comes before the snapshot read, so a withdrawal that commits later
finds the owner. A close that arrives during any step stops the admission with
`forbidden`, and closes the stream if it is already open. A `stale_access`
refusal reads the snapshot once more and opens again within the same deadline. A
second `stale_access` returns `timeout` and sends no third open. A node's
`unknown_biot` becomes `not_found`. Any failure unregisters the process.

`Access.handle_owner_message/2` handles each message an owner receives while it holds a
stream. A `:DOWN` from the control connection closes with `:control_lost`. The
expiry timer closes with `:expired`. `{:biot_access, :close}` closes with
`:policy`. Every other message returns `:ignored`. The expiry is the proof's live
expiry; an SSH key proof has none and gets no timer.

`Access.close/1` is the only close an owner may use. Both functions delegate to
`Admission`, so an owner uses only `Access` for its whole lifecycle. It removes every
registration, cancels the monitor and timer, and then closes the stream.
`Streams.close/1` alone leaves the owner registered. One process holds one
admission at a time, and `Owners.register/3` crashes if the process still holds
keys. `close_invalid_proof_owners/0` checks each distinct registered proof key
with `Validity.key_valid?/3` and closes the owners of every invalid key.

`Access.Owners` is a duplicate-key `Registry`. Its closure keys are
`{:biot, id}`, `{:principal, id}`, and the `Validity` proof keys, and they hold no
value. `register_connection/1` registers an authenticated LiveView under its principal and proof
keys only, without a Biot key, so a disable or logout closes every LiveView of that login. An
admitted owner also holds `{:admitted, stream_id}`. Its value is the
`Owners.Admitted` monitor and timer. `close/1` sends `{:biot_access, :close}` to
every process under a key. `proof_keys/0` returns each distinct proof key once.
`unregister/0` removes every key the calling process holds and returns its
`Admitted` values.

`CommitEffects.enforce/1` is the one post-commit fence. It takes a
`%CommitEffects{owners: ..., wakes: ..., readers: ...}` struct and closes owners,
wakes nodes, then notifies readers, in that order; `@enforce_keys` makes a
missing list a construction error. Owners close first because a node applies the
new access revision later, and a local stream must not stay open for that time.
Readers are notified last, after the change is visible to a new query. Its seven
callers are:

| Caller | Owners | Wakes | Readers |
| --- | --- | --- | --- |
| `Biots.after_commit/1` | the Biot on destroy | the Biot's node unless it is written off | the Biot on a change |
| `Policy.Transaction.after_commit/1` | the Biot on withdrawal | the Biot's node on withdrawal | the Biot unless unchanged |
| `Reports.observation/4` | none | none | the Biot when stored |
| `Reports.access_applied/4` | none | none | the Biot when stored |
| `Secrets.deliver/4` | none | none | the Biot after the exposure marker commits |
| `Nodes.commit_effects/1` | `{:biot, id}` for each bumped Biot | none | every Biot on a changed node |
| `Principals.apply_disabled_identities/1` | `{:principal, id}` for each disabled principal | each affected Biot's node | each affected Biot |

Proof deletions call `Owners.close_proof/1` directly after commit.
`Sessions.logout/1` closes `{:control_session, digest}`. A preview owner also
holds its parent's key, so logout closes its previews too. `Credentials.revoke/2`
closes `{:credential, id}`, and `SshKeys.remove/2` closes `{:ssh_key, id}`. A
delete that finds nothing closes no owner.

Two checks catch a close that was lost. `Control.Connection` closes the owners of
every Biot in `Synchronization.access_behind/1` at hello, before the snapshot, and
on each desired sweep. `Access.AuthSweep` calls `close_invalid_proof_owners/0`
every `auth_check_interval_ms`, and a nil interval disables it. The application
starts `Owners` and `AuthSweep` before `Principals.Startup`, because both startup
reloads close owners.

#### Identity records

`Sessions` owns control and preview browser sessions. `start_control/1` takes a
`PrincipalId`, reads the stored status, and inserts the control row in one
immediate transaction, so a disable cannot slip between the check and the insert.
`control/1` looks up a presented token. `preview/2` requires a matching hostname,
an unexpired preview row, a live parent session, and the same principal.
`require_control/2` rechecks a control proof on the caller's connection. All
three use the `Authentication.Validity` queries. `valid?/1` rechecks any authentication proof, and
`expires_at/1` returns its absolute expiry, or nil for an SSH key. `logout/1` rechecks the live
proof and deletes the control row, so previews and handoffs cascade. After
commit, it closes the session owners of that login and its previews.
`sweep_expired/1` deletes every session at
or past its expiry, and a deleted control row cascades to its previews and
handoffs.

`Credentials` owns labeled bearer credentials. `create/3` requires a live control
proof, caps the expiry at `credential_max_lifetime_ms`, and returns the clear
token once. The row stores only the token digest. `authenticate/1` reads the live
credential and records `last_used_at` at most once per
`credential_last_used_interval_ms`. `list/1` and `revoke/2` scope to the actor.
After its delete commits, `revoke/2` closes the session owners of that credential.
`Credentials.Created` is the result struct, and `Queries.CredentialView` is the
projection that never holds the clear token. `sweep_expired/1` deletes
credentials at or past their expiry.

`SshKeys` owns registered OpenSSH public keys. `add/3` parses the line, stores the
canonical line and fingerprint, and maps a duplicate fingerprint to
`already_registered`. `authenticate/1` takes a parsed `%SshPublicKey{}` and finds
only a key of an enabled principal. `list/1` and `remove/2` scope to the actor.
After its delete commits, `remove/2` closes the session owners of that key.
`Queries.SshKeyView` is the projection.

`PreviewHandoff` owns single-use preview codes. `begin/4` requires a live control
proof and view authority for an active publication. `finish/3` checks the
hostname, the challenge, the expiry, the live parent, and the current view
authority, then deletes the handoff and inserts the preview session in one
transaction. A preview session expires with its parent. `PreviewHandoff.Finished`
carries the preview token and the return path. `sweep_expired/1` deletes handoffs
at or past their own expiry, which is shorter than the parent's.

`Authentication` is `%Authentication{actor, proof}`. `AuthenticationProof` owns
the `control`, `preview`, `credential`, and `ssh_key` proof variants and their
constructors. A proof carries only stored identifiers and digests, never a clear
token. `AuthenticationProof.accepted_on?/2` says where a proof may open a stream.
A preview proof works only on its own preview host. Every other proof works on
any surface.

`Authentication.Validity` owns the shared live-proof queries: `control_session/3`,
`preview_session/4`, `credential/3`, `credential_by_digest/3`, `ssh_key/2`, and
`ssh_key_by_fingerprint/2`. Each one requires an enabled principal. A live preview
also needs an unexpired preview row and a live parent control session of the same
principal. `check/3` returns a proof's live expiry: the session or credential
expiry, the earlier of a preview and its parent, or nil for an SSH key.
`proof_keys/1` maps a proof to its closure keys, and a preview yields its own key
and its parent's control-session key. `key_valid?/3` checks one key, and
`proof_key?/1` separates proof keys from other `Owners` keys.

`Tokens.mint/1` returns a clear token and its digest. Minting reads randomness,
so callers treat it as an effect. `Tokens.digest/1` hashes a presented token.
`Label` owns the 1-to-100-byte label rule shared by credentials and SSH keys.
`Id.generate/1` mints a new canonical protocol ID.

#### OIDC login

`Login.start/1` creates the authorization URL and a `Login.Pending` value with
state, nonce, PKCE verifier, and a same-origin return path. `Login.finish/2`
uses the provider worker, checks the callback through `Login.Callback`, verifies
the ID-token claims, identifies the principal, and starts a control session.
Provider failures map to `:temporarily_unavailable`; identity and callback
failures map to `:unauthenticated`.

`Biot.Server.Application` starts `Oidcc.ProviderConfiguration.Worker` as
`Biot.Server.Login.Provider` when OIDC settings include an issuer. The worker
owns provider discovery and JWKS state. No worker starts when OIDC is unset.
The `biot_server` application declares the `oidcc` dependency for this flow.

#### Principal status and disabling

`Schema.Principal` stores `status`, an enum of `:enabled` and `:disabled`.
`Principals.require_enabled/2` is the one check for a disabled principal. Inside
an immediate transaction it runs after write ownership; read paths pass `Repo`.
A disabled principal gets `{:error, :unauthenticated}` at every application
boundary, and no error says whether the row is disabled, missing, or expired.

`Principals.reload/0` reads the configured disabled identities and applies them
in one immediate transaction. It inserts a disabled row for an unseen identity so
a later first login cannot become enabled. It disables configured enabled
principals and deletes their sessions, preview handoffs, credentials, and SSH
keys. It re-enables principals no longer configured without restoring proofs. It
bumps each affected Biot's access revision once. After commit, it closes the
session owners of each disabled principal, wakes each affected Biot's node, and
notifies each affected Biot's readers.
Ownership, grants, and history stay. A repeated reload changes
nothing, and an invalid file leaves the database unchanged.
`Principals.DisabledIdentities` loads and parses the file. Errors are typed, so an
invalid file fails before any write. `Principals.message/1` reports them.
`Principals.Startup` runs `reload/0` before the control listener and fails boot
on invalid configuration.

#### `Biot.Server.Policy`

`Policy.Applied` and `Policy.Unchanged` are the two successful policy results.
`Policy.enforcement()` is `:applied` or `{:pending, node_id}`.
`Policy.Transaction` owns the immediate transaction around each mutation. It
loads the Biot, authorizes the actor, checks that the Biot is not destroyed,
executes the callback's writes, and bumps the access revision on withdrawal.
`after_commit/1` runs the `CommitEffects` fence: a withdrawal closes the Biot's
session owners, wakes the node, and notifies the Biot's readers. It then reads
enforcement from `AccessObservation` and
live connection state, and builds the result.

Policy callbacks receive the transaction's repository and Biot. They return
`:unchanged`, `{:added, multi}`, or `{:withdrawn, multi}`. Additions keep the
current revision, do not wake the node, and still notify the Biot's readers.
Withdrawals add one revision, close the Biot's session owners, and wake the
assigned node.

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

`Publications.url/1` applies the configured domain to one parsed hostname for
handoff redirects. `Queries.PublicationView.url/2` is the shared URL formatter
used by both this function and publication projections.

`Queries.PublicationView` sorts publications by port and projects each row into
its port and HTTPS URL. `Queries.AccessView` projects loaded shell and view rows
into the owner ID, sorted shell principal IDs, and sorted `{port, principal_id}`
view grants. `Queries.BiotView` uses `Policy.Enforcement` for the access status
shown with the rest of the Biot view.

`Authorization.role/3` returns `:owner` or `{:collaborator, grants}`. Its policy
predicates keep lifecycle, policy, and grant reads owner-only. Three pure
predicates decide read and stream access for one loaded Biot:

- `may_read?/3` is true for the owner or any shell or view grant.
  `Access.readable/2` is its query form and must match it.
- `may_view?/4` is true for the owner or a matching view port on one publication.
- `may_shell?/3` is true for the owner or a shell grant.

A nil actor passes none of them.

These modules follow the model contract. Additions never move the access
revision. Unpublish deletes the port's view grants in the same transaction.
Destroy deactivates publications and removes shell and view grants in one
transaction.

#### `Biot.Server.Streams`

`Biot.Server.Streams` is the owner's stream API. `open_until/5` finds a node's
ready connection, registers the open with `Pending`, sends `OpenStream`, and
waits for the attach before a caller-owned monotonic deadline. On success it
returns a `Stream` the caller owns. Admission sets one deadline of
`stream_open_timeout_ms`, so its one retry shares the first open's deadline.

`stream/2` turns one message into typed events. A port stream reports
`{:data, bytes}`, `:closed`, or `:lost`. A shell stream decodes its frames and
reports `{:data, bytes}`, `{:exit, status}`, `:closed`, or `:lost`, and a frame
that does not decode closes the socket. Anything else returns `:unknown`, so a
caller can pass every message it receives. `ask/1` re-arms one read, which is the
backpressure: the node cannot send the next chunk until the owner asks. `write/2`
sends port bytes or one shell data frame per 64 KiB. `resize/3` sends a resize
frame, and `close/1` closes the socket.

`Streams.Pending` owns the opens that were sent to a node but not yet attached.
`register/6`, `attach/5`, `stream_failed/2`, `control_lost/1`, and `abandon/1`
all run in one process, so exactly one of attach and abandon wins. It checks the
node and connection identity against `NodeConnections`, and a control loss
reports `:node_unavailable` to every caller on that connection.

### Control protocol

- `Control.Listener` accepts mutually authenticated TLS node connections.
- `Control.Connection` owns one process per node connection.
  It handles hello, snapshot synchronization, ready, wake, desired sweeps, reports,
  heartbeats, diagnostics, runtime-log requests, and the five secret and credential request calls.
  Secret requests use the existing pending-request timers; the timer starts before the send. `:no_allocation`
  and every node failure map to `:temporarily_unavailable`, while late replies are dropped.
  It sends `registration_abandoned` when an abandoned node attempts a connection.
  It sends one snapshot from one `Synchronization.specs/1` list as `SynchronizeBegin`,
  `SynchronizeItem` messages, and `SynchronizeEnd`. The connection schedules its first
  sweep one `desired_sweep_interval_ms` after ready and reschedules after each sweep.
  Wakes during synchronization are dropped because the next sweep repeats the comparison.
- `Control.Connection.open_stream/3` sends `OpenStream` on a ready connection or returns
  `:node_unavailable`. An `attach` frame authenticates the stream connection, rejects any byte
  after the frame with `:unknown_stream`, claims the pending stream, sends `Attached`, and hands
  the socket to the owner with `:ssl.controlling_process/2`. The handler then holds no socket data
  and closes when the owner exits.
- The server starts `Control.Registry` before `Nodes.Startup` and starts the listener after `Nodes.Startup`.
  The connection claims its node with `NodeConnections.put/2` in the `:synchronizing` state and
  moves to `:ready` after `synchronized`. When another process holds the node, the new connection
  sends it `:replaced`, waits for it to exit, and claims again, so the newest connection wins.
- `Control.Synchronization.behind/2` runs one query. It returns Biots whose desired
  revision or access revision this connection has not accepted. The sweep resends
  `desired` for those Biots, built by `BiotSpecs.build/1`.
- `Control.Synchronization.access_behind/1` returns the included Biots on a node whose
  access revision is ahead of the last one the node applied on any connection. The
  connection closes their session owners at hello, before the snapshot, and on each
  desired sweep. This reaches a withdrawal whose request process died before it closed owners.
- `Reports.observation/4` and `Reports.access_applied/4` require the assigned node
  and the current connection through `NodeConnections.current?/2`. Equal or lower
  access revisions return `{:ignored, :revision_ahead}`. Reports from another
  connection return `{:ignored, :stale_connection}`. The connection logs ignored
  reports at debug level.
- `AccessApplied` is accepted during synchronization because the node sends it
  before `synchronized`.
- `Biot.Server.RuntimeLogs.get/2` reads a Biot's bounded runtime log after `Access.fetch_readable/2`,
  using the configured `node_response_max_bytes` bound; `get/3` takes an explicit bound. Owners and
  shell collaborators may read it. View-only collaborators may not.
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

Server migrations live under `priv/repo/migrations`. `Biot.Server.Migrator` runs them at boot before
anything reads the database, so a release can start against a new SQLite file without a separate
migration command. Raw SQL is used only where SQLite requires composite foreign keys inline.

The schema includes principals and nodes, Biot intent and environments, access policy and applied
access observations, operations and node observations, browser sessions and preview handoffs,
bearer credentials, and SSH keys. Principals are never deleted, so sessions, credentials, and keys
do not cascade from them. Preview sessions and handoffs do cascade from their control session.

### Tests

`test/support/data_case.ex` gives tests a sandboxed Repo.
`test/support/fixtures.ex` builds rows.
Integration tests hit the real SQLite test database.

The suite exercises lifecycle, enrollment, policy, projections, authentication, stream admission,
control synchronization, and failure handling through real SQLite transactions and real OTP
processes. Pure planner, authorization, projection, and parser tests use properties and exhaustive
tables. Integration harnesses speak the actual TLS control protocol and, where stream behavior is
under test, run the real Go agent. No tests mock internal module calls.

## `apps/biot_web`

The web app owns the HTTP API, browser login, the LiveView UI, and the browser terminal. The
preview proxy and preview callback consumer are not built yet.

### Application and request boundaries

- `BiotWeb.Application` starts `BiotWeb.PubSub` and `BiotWeb.Endpoint`.
- `BiotWeb.Endpoint` serves static assets and the LiveView socket, parses requests, applies the
  Phoenix session, and installs `BiotWeb.Router`. It resolves the client address before telemetry.
  Both LiveView transports accept only the endpoint's exact origin.
- `BiotWeb.Router` has a browser pipeline with sessions, CSRF, control-origin checks, and
  `ControlSession`. The browser scope serves the landing page, login, logout, the terminal socket
  upgrade, and an authenticated `live_session` whose `on_mount` hook is `LiveAuth`. Its API pipeline
  accepts JSON and requires a bearer credential. The API fallback handles unknown paths with the
  same error body.
- `BiotWeb.ClientAddress` parses `BIOT_TRUSTED_EDGE_PEERS` as individual IPv4 or IPv6 addresses.
  `resolve/3` trusts `X-Forwarded-For` only when the immediate peer is listed, and uses the last
  parsed entry. It canonicalizes IPv4-mapped IPv6 addresses and keeps the peer address on failure.
- `BiotWeb.Cookies` owns `__Host-biot_session` and `__Host-biot_login`, their `Secure`, `HttpOnly`,
  `SameSite=Lax`, path, and lifetime attributes. The login cookie is sealed pending OIDC state;
  the session cookie holds only the control token and CSRF token.
- `BiotWeb.Params` is the pure request parser. It keeps path and body fields separate, parses
  protocol values, collects invalid fields, and applies the page default of 50 and limit of 200.
- `BiotWeb.Plugs.ControlSession` authenticates the session token through `Sessions` and removes a
  dead token. `BiotWeb.Plugs.ControlOrigin` permits safe methods, no `Origin`, or the configured
  control origin; another origin raises a 403 error before CSRF checks.
- `BiotWeb.PreviewPaths` owns the reserved `/__biot/callback` path used in preview handoff URLs.
- `Phoenix.Param.Biot.Protocol.BiotId` in `route_param.ex` is the one place a `BiotId` becomes a URL segment, so every `~p` route interpolates the struct directly.
- `BiotWeb` provides the Phoenix controller, router, HTML, and LiveView macros. `Layouts` embeds
  the root template, while `ErrorHTML` renders status messages and `ErrorJSON` returns
  `{"error":"internal"}` for crashes and a status tag for other endpoint errors.

### API modules and routes

`BiotWeb.Api.BearerHeader` accepts exactly one case-insensitive `Bearer` value.
`BiotWeb.Api.Bearer` authenticates it with `Credentials` and does not read
browser cookies. `BiotWeb.Api.Authenticated` supplies the actor to controllers.
Controllers parse input, call one server function, and pass views through
`BiotWeb.Api.Json`.

| Route | Controller | Server boundary |
| --- | --- | --- |
| `GET /api/me` | `MeController` | `Principals.get` |
| `GET /api/deployment` | `DeploymentController` | `Queries.Deployment.get` |
| `GET /api/nodes` | `NodeController` | `Queries.Nodes.list` |
| `GET /api/principals?email=` | `PrincipalController` | `Principals.resolve_email` |
| `GET /api/biots` | `BiotController` | `Queries.Biots.list` |
| `PUT /api/biots/:id` | `BiotController` | `Biots.create` |
| `GET /api/biots/:id` | `BiotController` | `Queries.Biots.get` |
| `DELETE /api/biots/:id` | `BiotController` | `Biots.destroy` |
| `POST /api/biots/:id/start` | `BiotController` | `Biots.start` |
| `POST /api/biots/:id/stop` | `BiotController` | `Biots.stop` |
| `POST /api/biots/:id/environment` | `BiotController` | `Biots.update_environment` |
| `GET /api/biots/:id/publications` | `PublicationController` | `Publications.discover` |
| `PUT` and `DELETE /api/biots/:id/publications/:port` | `PublicationController` | `Publications.publish`, `unpublish` |
| `GET /api/biots/:id/grants` | `GrantController` | `Access.get_grants` |
| `PUT` and `DELETE /api/biots/:id/grants/shell/:principal_id` | `GrantController` | `Access.grant_shell`, `revoke_shell` |
| `PUT` and `DELETE /api/biots/:id/grants/view/:port/:principal_id` | `GrantController` | `Access.grant_view`, `revoke_view` |
| `GET /api/biots/:id/secrets` | `SecretController` | `Secrets.list` |
| `PUT` and `DELETE /api/biots/:id/secrets/:name` | `SecretController` | `Secrets.deliver`, `remove` |
| `PUT` and `DELETE /api/biots/:id/fetch-credentials` | `FetchCredentialController` | `FetchCredentials.deliver`, `remove` |
| `GET /api/biots/:id/logs` | `LogController` | `RuntimeLogs.get` |
| `GET /api/operations/:id` | `OperationController` | `Operations.get` |
| `GET /api/diagnostics/:ref` | `DiagnosticController` | `Diagnostics.get` |
| `GET /api/credentials` and `DELETE /api/credentials/:id` | `CredentialController` | `Credentials.list`, `revoke` |
| `GET /api/ssh-keys` | `SshKeyController` | `SshKeys.list` |
| `POST /api/ssh-keys` | `SshKeyController` | `SshKeys.add` |
| `DELETE /api/ssh-keys/:id` | `SshKeyController` | `SshKeys.remove` |

`Json` encodes server views, protocol unions, IDs, ports, times, diagnostics,
and runtime logs. `Response` maps accepted lifecycle results to 202 with one
operation location, unchanged lifecycle results to 200, policy results to 200,
new SSH keys to 201, and bare effects to 204. `Reply` applies those status,
headers, and bodies. `ErrorResponse` maps `CommandError` values to the model's
status and error fields. `FallbackController` handles action errors and API
fallbacks. Credential creation has no API route; the account LiveView creates credentials.

### Browser login and preview handoff

- `BiotWeb.LoginController` validates a same-origin return path, calls `Login.start/1`, seals
  `Login.Pending` in the ten-minute `__Host-biot_login` cookie, and redirects to the provider.
  The callback opens that cookie, calls `Login.finish/2`, rotates the Phoenix session, stores the
  control token, removes the login cookie, and returns to the stored path. Missing, forged, expired,
  or failed login state has one generic 401 response; unavailable provider state is 503.
- `BiotWeb.PreviewAuthorizeController` parses the host, challenge digest, and return path. A live
  control session calls `PreviewHandoff.begin/4` and redirects to the publication URL plus
  `PreviewPaths.callback()`. An absent session redirects through `/login` and preserves this
  request. Invalid input, missing publication, and missing view authority return 400, 404, and 403.
- `BiotWeb.SessionController` logs out the current control session and redirects to `/`; the server
  closes its previews and handoffs while other logins and credentials remain valid.

### Browser UI

The LiveView UI serves every browser page and calls server application functions directly. It never
calls the HTTP API.

- `BiotWeb.LiveAuth` is the `on_mount` hook for the `:authenticated` live session. It reads the
  control token, loads it with `Sessions.control/1`, assigns `authentication` and `actor`, and
  registers the LiveView with `Owners.register_connection/1`. It keeps the same-origin return path
  for re-login, schedules the proof's expiry, and, when `auth_check_interval_ms` is set, rechecks
  the proof on that interval. A close message, an expired proof, or a failed check redirects to
  `/login?return=...` after it unregisters the process.
- `BiotWeb.UserMessage` is the one browser vocabulary for command errors, failures, invalid fields,
  and enforcement status.
- `BiotWeb.BiotState.current_failure/1` picks the failure from the current operation or the latest
  observation, so the list, detail, and creation views agree.
- `BiotWeb.Live.Navigation.counts/1` supplies the readable Biot count and node count, or nil when a
  read fails.
- `BiotWeb.Components.AppShell` renders the shared frame: sidebar navigation with those counts, the
  mobile header, logout, and the content slot.

The pages are `Live.LandingLive` (`/`), `Live.BiotsLive` (`/biots`), `Live.NewBiotLive`
(`/biots/new`), `Live.BiotLive` (`/biots/:id` and its tabs), `Live.TerminalLive`
(`/biots/:id/terminal`), `Live.NodesLive` (`/nodes`), and `Live.AccountLive` (`/account`).

- `Live.BiotTabs` owns the tab vocabulary (`:overview`, `:publications`, `:access`, `:secrets`,
  `:logs`), the tabs a role may see, and the load message for one tab.
- `Live.BiotDetailData` owns the detail, deployment, secret, and log reads for one Biot.
  `waiting_fetch_source/1` reports the fetch-credential wait only for the current running
  operation.
- `Live.ShellAvailability.allowed?/1` is the one rule for the terminal action: owner or shell
  collaborator, ready node, running container, and not destroyed.
- `Live.BiotLive` loads the overview and owns the lifecycle actions. Start, stop, and rebuild send
  the revision the page last loaded; a `revision_conflict` reloads and explains. Destroy arms
  inline. On `handle_params`, a connected page subscribes to `BiotChange` for the shown Biot,
  re-subscribing only when the route Biot changes, and unsubscribes on an invalid ID. It reloads
  the same authorized projection on `{:biot_changed, biot_id}` and ignores a message for another
  Biot, so another session's change or a node observation updates the page in place.
- `Live.BiotTabLive` owns one tab's reads and mutations: publish, unpublish, share, revoke, deliver
  and remove runtime secrets, deliver a fetch credential, and read runtime logs. Secret and log
  reads run as async work, and a failed read never becomes an empty list.
- `Live.NewBiotForm` parses the creation form into one `Biots.Create` command plus runtime-secret
  and source-credential lists. It forces `initial_state: :stopped` when any credential is present.
- `Live.NewBiotWorkflow` is the pure creation state machine. It advances through allocation,
  source-credential delivery, preparation, runtime-secret delivery, and starting, deciding to wait,
  deliver, start, finish, or fail. `Live.NewBiotLive` polls the created view and runs it.
- `Live.AccountLive` creates bearer credentials and SSH keys, shows the clear token once, and
  revokes either.
- `Live.NodesLive` renders the node inventory and expands its orphan report.

The `/biots` list page does not subscribe to `BiotChange`; an open list tab keeps its snapshot and
needs a manual reload. Only the detail page updates in place.

The components `Access`, `BiotLogs`, `BiotOverview`, `BiotSecrets`, `Publication`, `Operation`,
`OrphanReport`, `Role`, `Status`, and `BiotSummary` each render one panel or one projected value.
`BiotSummary.value/1` is the one list-summary priority order, and `Status` and `Role` format the
finite status and role vocabularies.

### Browser terminal

- `BiotWeb.TerminalController.upgrade/2` validates the exact origin, resolves the client address,
  rechecks the control session from the cookie, parses the Biot ID and the requested terminal size,
  and upgrades the request to `TerminalSocket` with a 65,536-byte frame bound.
- `BiotWeb.TerminalSocket` is the WebSock handler and the stream owner. It opens with
  `Access.open_shell/3`, passes every process message through `Access.handle_owner_message/2`, and
  closes with `Access.close/1` on every termination path. Binary frames are shell bytes, a text
  frame is `{"resize": {cols, rows}}`, and the exit frame sends `{"exit": status}` before it closes.
- `assets/js/app.js` loads the vendored Ghostty Web terminal and defines the browser hooks
  `GhosttyTerminal`, `FormBehavior`, `LocalizedTime`, `AppearanceControls`, `CredentialNotice`, and
  `CopyCredential`.

### Browser assets

`mix biot_web.assets` copies the hand-written `assets/css/app.css` and the vendored Ghostty Web
JavaScript, WebAssembly, and license files into `priv/static`. `mix esbuild` bundles
`assets/js/app.js`. The Space Mono fonts and `favicon.svg` live directly under `priv/static`.

### Tests

`BiotWeb.ConnCase` owns the SQL sandbox and JSON request helpers. `TestFixtures`
builds principals, nodes, Biots, and environments through server records.
`BiotWeb.OidcPeer` is a real Bandit test provider with discovery, JWKS, `/authorize`, and `/token`.
It records state, nonce, and S256 challenge values, verifies client credentials and PKCE, signs
RS256 ID tokens, and consumes authorization codes once.

The web suite exercises every API route against real SQLite, browser and bearer separation, CSRF
and exact-origin rules, cookie scope, logout closure, OIDC discovery and PKCE against a real local
provider, and preview handoffs. Property tests fuzz bearer, callback, parameter, and client-address
boundaries.

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
  Running convergence runs data, environment, execution, then release.
  Stopped convergence retires execution first, then runs data, environment, and release, so a
  stopped Biot still resolves, prepares, and installs its selected environment without starting it.
  Destruction runs execution, release, then data.
- `BlockReason` includes `{:inspection, failure}`, `{:current_action, action}`, `{:recorded_failure, failure}`, and `{:fetch_credential, source}`. `Retry.classify/4` maps host outcomes to bounded failures and retry policies; a credential wait is the one operator-owned block. `Reconcile.next/3` blocks running and stopped intent on that wait, but lets destruction proceed.
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

The controller's `phase` makes its waiting state explicit. It also owns a FIFO `requests` queue for `SecretRequest` values. `Controllers.secret_request/2` finds an existing controller and returns `:no_allocation` otherwise; it never starts a controller. `serves_requests?/1` is a closed decision over every phase, and `finish_action/3` is the one safe point that records the lifecycle result, drains eligible requests, and converges. The deferred `:converge` wake is sent only by the cast path that clears a credential wait; recovery and action completion use their existing convergence path.

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
controller's pending container exit, recorded failure, and `waiting_for`. `Observation.report/2`
projects the inspected state into the server's `ExecutionReport`, preserving the wait for the server and `BiotView`.

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
`pending_exit`, `failure`, and `waiting_for`, and builds the `NodeState` that reconciliation consumes.
`run/2` returns `:ok | {:waiting_for, source} | {:error, Host.Outcome.t()}` and dispatches totally over
every `Biot.Node.Action` variant. `SecretRequest` is the closed five-operation request set; `Host.serve/2`
answers it against an existing allocation without creating one. `Control.Connection.reply/4` returns the
result on the requesting link. The pure core has no worker state: workers are never desired or adopted,
and recovery is an imperative precondition.

The effect modules own host resources:

- `Host.Allocation` creates or repairs an allocation, its network, checkout, mounts, private Nix
  root, scratch, and initialization marker. It grants and reclaims mapped ownership, removes data,
  and releases the allocation only after its worker is absent.
- `Host.Environment` resolves, prepares, installs, and releases environment resources. Every Nix
  command runs in `Host.Worker`; release confirms worker absence, removes the environment, collects
  the private store, and deletes the resolution record last.
- `Host.Container` starts and retires rootless Podman containers. `run_container` uses the bundle's
  physical `--rootfs`, `--read-only`, `/tmp` and `/run` tmpfs mounts, the five allocation mounts,
  and a read-only `/nix/store` mount. Its stable runtime name is `biot-<BiotId>`. Inspection resolves
  that name to Podman's native container ID, and retirement removes that exact inspected ID so it
  cannot remove a later incarnation. `Host.Network` creates, inspects, and removes named private
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
  `XDG_CACHE_HOME`. `Layout.variables/2` and `mounts/3` are the only phase-aware layout points:
  fetch alone gets the credential include mount and `BIOT_NODE_FETCH_CA_BUNDLE` as
  `GIT_SSL_CAINFO` and `NIX_SSL_CERT_FILE`; build and collect get neither. Its tmpfs set is `/tmp`,
  `/root`, `/var`, and `/nix/var`. The UID/GID map
  confines files to the allocation's range; the isolated network confines traffic to the Biot;
  `--read-only` confines writes to explicit mounts and tmpfs; `unmask=/proc/*` lets Nix create its
  nested sandbox; `SYS_ADMIN` lets that sandbox mount its namespace; `--rm` and log driver `none`
  keep the disposable worker from retaining a root or logs. The probe uses the same boundary with
  no allocation, no network, and a throwaway store.
- `Host.SourceStaging` owns trusted fetch, copying the release's `nix/` and `agent/` support,
  running `nix/fetch.nix`, and reading the staged out-link. `pins.json` is the one output contract.
  `Host.StagedInputs` is its pure, strict value: build support, Nixpkgs, layers, store paths,
  hashes, and revisions. The staged out-link is the GC root for that complete input set.
- `Host.PrivateStore` owns `host_path/3`, which maps a logical `/nix/store` object into the Biot's
  physical store, and `object_at/3`, which follows an out-link through that mapping.
- `Host.Git` is the one hardened Git shape: HTTPS-only transport, disabled system and global
  configuration and credentials, no prompt or askpass, no submodule recursion, and an empty
  template. `Git.environment/1` takes either `:no_credentials` or a credential include scope;
  `Git.authentication_failure/2` identifies a unique longest URL match, then a unique origin match.
  `Biot.Protocol.RepositorySource` enforces HTTPS before a repository reaches Git.

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
  long-running command. `Host.Podman` adds the configured Podman module; `exists/3` distinguishes
  present, absent, and failed checks from `podman <resource> exists` exit statuses.
- `Host.ContainerEvents` reads Podman's `events` stream through `Command.open/5`, closes and
  reopens it after `container_events_retry_ms`, and uses `Names.owner/1` for ownership.
- `Host.Secrets` publishes runtime secret files atomically under the allocation's `secrets` directory.
  `Host.FetchCredentials` writes URL-scoped Git fragments, the relative `include.config` file, and
  exposes the scoped path through `scope/2` under the node-owned, unmounted `fetch-credentials` directory. `Host.FileSystem.publish/4` owns same-directory staging,
  permission and ownership preparation, atomic rename, and cleanup; `unlink/1` is idempotent. `Host.Podman.share/3`
  gives a credential fragment to the mapped user while `grant/3` handles the runtime secret tree.
- `Host.Paths` owns the node-private layout. Everything Nix owns is below the Biot: `store_root`,
  `store`, `scratch`, `build_support`, `environments`, `environment`, `staged`, `environment_root`,
  `runtime_mounts`, and `allocation_owned_directories`. `Paths.allocation_directories/2` is the one
  owner of required allocation directories, their owner, and their mount: secrets are node-owned and
  mounted read-only, while fetch credentials are node-owned and unmounted. It also owns
  `worker_nix_config` and `git_template`. `Host.PrivateStore` maps the logical store into the physical
  one. The old zero-arity `Git.environment/0` and `Layout.variables/0`, plus
  `Paths.mounts_created_at_allocation/2` and `Paths.node_owned_directories/2`, were replaced by
  the scoped and phase-aware APIs.
- `Host.Names` derives worker and probe names, network names, and labels. Workers use one stable
  `biot-worker-<id>` name with `io.biot.biot-id`, `io.biot.role=worker`, and a phase label; the
  startup probe is `biot-worker-probe` with `io.biot.role=probe`. `Host.Network` creates isolated
  networks with Podman's `--opt isolate=true` option. `Host.FileSystem` provides tri-state
  inspection, atomic writes, and tree removal.
- `Host.Podman.grant/3` gives a tree to the mapped allocation user. `reclaim/2` uses `podman unshare`
  to restore node ownership and write permission before removal. `Host.Config.load/0` parses and
  validates operator settings once at boot and keeps the result in `:persistent_term`; later effects
  use `current/0` or the boot-order invariant behind `current!/0`. `Host.Context` binds those settings
  to one Biot ID.
- `Host.Setup` creates the node layout, the empty Git template, and the worker `nix.conf`. That
  configuration contains operator substituters and trusted keys, `sandbox = true`,
  `sandbox-fallback = false`, and `require-sigs = true`. Its startup sandbox probe rejects a host
  without nested isolation rather than allowing Nix to build unsandboxed.

Environment storage and the runtime store belong to the Biot's private allocation; the runtime
receives that private store read-only at `/nix/store`.

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
`Journal.Migrator` runs the compiled migrations under `Biot.Node.Journal.Migrations`. Compiled
modules load once even though tests create many journals in one VM, avoiding repeated module
redefinition from dynamically compiled migration files.

Journal queries scope resolution and installation reads and writes by Biot ID,
then check environment ownership before cross-resource changes. Its ownership
transactions use SQLite immediate mode. SQLite foreign keys restrict allocation
deletion while an installation or resolution remains, and the journal also checks
that no such records remain before release. `next_uid_start/3` finds the first
unused configured range, while the unique `allocation_uid_start` index closes the
concurrent-insert race.

`Journal.put_intent/1` and `Journal.replace_intents/1` accept intent and drop a
superseded retry row in the same transaction. `Journal.record_waiting_for/4` records the source and
returns the attempt that was counted; `clear_waiting_for/2` clears it when the matching credential is
published. `RetryState.wait_for_credential/3` stores `{:fetch_credential, source}`, clears retry
failure and time, and returns the attempt without charging the wait as an additional attempt. `replace_intents/1` also deletes
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

`nix/agent.nix` builds the vendored Go agent with `buildGoModule` and no module download.
`nix/fetch.nix` resolves refs and stages source trees, hashes, and this release's build support.
`nix/build.nix` accepts only those staged paths and hashes under pure evaluation and writes bundle
JSON. It builds `rootfs`, `entrypoint`, `shell_entrypoint`, and one environment file.
`loadEnvironment` is the one secret-loading rule: it loads the bundle
environment, then entry-specific variables, then files under `/biot/secrets`; its sentinel read
preserves empty values and trailing newlines. `cleanEnvironment` is
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
`PATH`, and `TERM` are reserved environment names. `SecretName` uses the same reserved names, so
Nix and protocol delivery cannot disagree. Compatible module definitions merge; conflicting
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

`config/config.exs` supplies server request and node defaults. `BIOT_NODE_FETCH_CA_BUNDLE` is an
optional complete absolute trust bundle. It replaces the image trust store, applies only to the
fetch phase, and must include public roots as well as private authorities; the same contract is
documented in `Host.Config` and `nix/README.md`. The request, capture, controller, and diagnostic settings are:

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
| `max_streams` | `128` | `BIOT_NODE_MAX_STREAMS` |
| `max_streams_per_biot` | `16` | `BIOT_NODE_MAX_STREAMS_PER_BIOT` |
| `max_frame_bytes` | `1_000_000` | `BIOT_MAX_FRAME_BYTES` |
| `builder_image` | pinned digest | `BIOT_NODE_BUILDER_IMAGE` |
| `fetch_ca_bundle` | none | `BIOT_NODE_FETCH_CA_BUNDLE` |
| `binary_cache_urls` | `https://cache.nixos.org` | `BIOT_NODE_BINARY_CACHE_URLS` |
| `binary_cache_keys` | cache.nixos.org key | `BIOT_NODE_BINARY_CACHE_KEYS` |
| `worker_timeout_ms` | `3_600_000` | `BIOT_NODE_WORKER_TIMEOUT_MS` |

`max_frame_bytes` is read from application configuration only by the node
connection. `config/releases/node.exs` reads data-root, UID/GID range, executable, connection,
heartbeat, reconnect, Podman, TLS, and build settings for the node release. The node release carries
the exact `nix/` and `agent/` sources it was built with under `biot_node/priv/build_support`; that
path is not an operator setting. Builder images must include a digest. Numeric `BIOT_NODE_*`
overrides must meet the bounds in release configuration. `Host.Setup` loads complete host
configuration before any effect reads it.

### Stream boundary

`Biot.Node.Streams` is the node's stream boundary. It holds one group per Biot,
the current control connection, and the applied access revision, and it
serializes revision changes with admission, so a child cannot join a closing
group. `apply_revision/3` closes the old group and waits for every live child to
exit before its caller acknowledges, and it ignores a lower revision.
`admit/6` checks the group, its connection and revision, and both stream limits.
`close_all/0` empties every group.

`Streams.Groups` is the pure decision core. `apply_revision/4` returns
`:applied` with terminate effects, or `:ignored`. `admit/5` refuses with
`:unknown_biot`, `:stale_access`, or `:too_many_streams`. A group's child PIDs
are its only membership record, and `child_down/2` deletes one. `close_all/1`
returns every child to terminate.

`Streams.Supervisor` owns the boundary and the control connection as one
`:one_for_all` unit, so either crash restarts both and every stream closes.
`Streams.Children` is the `DynamicSupervisor` under it. `Streams.Stream` is one
admitted child. It does no IO in `init/1`; the agent connection, peer check, and
server attach run in `handle_continue/2`, so a slow agent cannot stall revision
application. It never restarts, its termination closes the sockets it owns, and
two linked relays splice the agent and server sockets through one re-framing
rule.

`Streams.Agent` opens one Biot's agent socket and reads the connected peer's
kernel credentials through `:socket.getopt_native/3` (`SO_PEERCRED`) before it
writes any target byte. It requires the host UID to lie in the allocation's
mapped range, so a replaced or symlinked socket cannot reach another Biot's
agent. It sends the target line and parses the bounded reply into `AgentReply`.

`Streams.Attach` dials the server through `Control.Dial` and completes the
attach handshake. Its first frame is `attach`, not `hello`, and it returns the
bytes that arrived with `attached` untouched. `Control.Dial` is the one mutual
TLS dial for the control connection and every attach. It verifies the server fingerprint and sets
`nodelay` because control requests, heartbeats, and shell keystrokes are small writes that wait on
replies. `Deadline` is a monotonic deadline for the node's bounded reads.

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
file for a Biot. The index is authoritative. Unlink failures are logged. `put/4` returns the stored
diagnostic ID or a typed failure, and `Journal.diagnostic_truncated/1` answers the retained metadata.

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
`Journal.replace_intents/1`. After either durable write, the node applies the revision at the
stream boundary, which closes the old group and waits for every live child to exit, and only then
sends `access_applied`. A reconnected node closes every group before it applies the synchronized
revisions. The node hands controller starts to `Controllers` before it sends `synchronized`.
After that acknowledgement, the
connection compares journal allocations with synchronized intents and puts orphan reports in the
outbox. The connection replays stored destruction reports when it becomes ready and after each
repeated `desired` message. The application starts this connection only after host configuration,
the journal, and the controller tree are ready. Linux is required for the node control path.

### Tests

`test/test_helper.exs` excludes `:linux` tests outside Linux and `:nix` tests when
`nix` is unavailable. Pure tests cover the reconciliation decision tables, retry rules, staged-input
parsing, layouts, Git hardening, and stream-group state. Integration tests use real SQLite journals,
OTP supervision, Unix sockets, the Go agent, Podman, and Nix as appropriate. The Linux host suite
covers worker isolation, cancellation, mounts, ownership, private stores, environment release,
runtime logs, secrets, credentials, and state across container restarts.

The Go agent suite includes request and frame fuzz targets plus real Unix-socket, TCP-relay, and PTY
tests. CI runs it directly; `docker/linux-host/run-tests.sh` runs the full Mix suite in the privileged
Linux host image.

## Releases

The root Mix project defines two releases.
The `server` release includes `biot_protocol`, `biot_server`, and `biot_web`. Before assembly it
builds the web assets, and after assembly it verifies the hashed stylesheet, JavaScript, vendored
terminal, favicon, and font files under the release's static directory.
The `node` release includes `biot_protocol` and `biot_node`; the node app's private files contain
the Nix and agent source trees used by its build workers. Each release has its own parsed runtime
configuration under `config/releases/`.

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

The root and `apps/biot_server` `test` aliases load `mix/test_env.exs`. Its `Biot.Mix.TestEnv.require_test_env!/1` refuses to run unless `Mix.env()` is `:test`, and it runs before `ecto.drop`, so `MIX_ENV=dev mix test` cannot drop the dev database.

Build and vet the CLI, and vet and test the agent, with:

```sh
cd cli
go build ./...
go vet ./...

cd ../agent
go vet ./...
go test ./...
```

## CI

`.github/workflows/ci.yml` installs Nix and sets up Erlang 28.5, Elixir 1.20.4, and Go 1.26.x.
The checks job runs `mix check`, the non-Podman Mix suite with warnings as errors, and the CLI and
agent Go checks. The host-tests job runs the full Mix suite in the privileged Linux host image.

## Configuration

`config/test.exs` uses `_build/test/biot_server_test.sqlite3` and the Ecto SQL sandbox.
`config/releases/server.exs` requires an absolute `BIOT_SERVER_DATABASE`, parses the control host
and publication domain as DNS names, rejects an overlapping control host, and requires complete
HTTPS OIDC settings. It also owns server TLS, listener, heartbeat, sweep, request, stream, SSH,
session, credential, operator-file, and trusted-edge settings. The login callback is
`https://<PHX_HOST>/login/callback`. Phoenix filters `value`, `code`, `state`, and `challenge` from
request logs.

`config/releases/node.exs` requires the data root, builder image, binary-cache configuration,
server identity, registration ID, and node TLS files. It parses numeric bounds and configures the
host tools, UID ranges, retries, observation, diagnostics, runtime logs, stream limits, and control
connection. The node release supplies build support itself.

## Host tests in Docker

Build the Linux host image, then run host tests with privileged access:

```sh
docker build -t biot-linux-host docker/linux-host
docker run --privileged --rm -it biot-linux-host
```

Run the full suite on Linux with `docker/linux-host/run-tests.sh` from the repository root. The
script archives tracked and unignored source inputs into a clean container workspace, so ignored
test output cannot affect the run.
