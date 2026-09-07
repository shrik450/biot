# Biot design

The [README](../README.md) defines the product and its scope. This document defines the
boundaries and behavior needed to build it. Protocols, library choices, and
operating-system configuration belong with their implementations.

## System boundary

Biot has one server and a few (1+) nodes. The server owns durable intent and
access control; nodes provide shared capacity and run the biots. A biot stays on
the node chosen at creation, either explicitly or through a configured default.
There is no scheduler or automatic migration.

The server serves the API and web UI, authenticates people through OIDC, and
stores biot definitions, permissions, and hostname allocations in SQLite. The
CLI and web UI expose the same operations through this API.

Nodes build Nix environments, manage Podman containers and working data, and
provide access to their terminals and services. The server can remain available
when a node fails; it cannot promise to control an unreachable machine.

An external reverse proxy terminates public TLS and forwards the control host
and preview hosts to the server through static configuration. Biot proxies
preview requests itself, keeping authorization and routing in one place.

```text
CLI / web UI -> server: identity, permissions, desired state
               server <-> node: apply changes, report actual state

browser -> edge TLS -> server: authorize -> node -> biot service
browser -> edge TLS -> server: authorize -> node -> biot terminal
SSH client -> node's published SSH endpoint: authorize -> biot shell
```

The operator supplies connectivity, DNS, and edge certificates. Server–node
traffic is encrypted and mutually authenticated. Each endpoint authorizes the
specific peer and its role; network location alone is not authority. Nodes are
trusted with the workloads and credentials assigned to them. Disabling a node
removes its authority to participate in the system.

## Implementation boundaries

The server and node use Elixir/OTP. Processes own node connections, biot
lifecycle coordination, and active sessions. Supervision manages their execution
and recovery; durable intent remains in SQLite, and reconciliation restores
coordination after restarts.

Domain decisions remain ordinary functions. Long-running builds and traffic
streams execute separately from lifecycle controllers so they cannot block
permission changes or destruction.

Phoenix LiveView and the HTTP API call the same application operations. The Go
CLI consumes that API and handles authentication, arguments, output, and progress
reporting. Authorization and lifecycle policy remain on the server.

Nix modules compose environment layers into buildable artifacts. The node
invokes Nix and manages artifact lifetimes and activation. Go's initial scope is
the CLI; additional language boundaries require a concrete implementation need.

## State and lifecycle

A biot has a stable ID, an owner, an assigned node, and a desired configuration.
That configuration describes its environment inputs, credential grants, and
whether it should be running, stopped, or destroyed. Published ports and access
grants belong to the stable biot, not to a particular container instance.

The server records desired changes before asking the node to apply them. The
node reports what is actually running and which configuration it has applied. An
accepted request and a completed operation are distinct: clients can see pending
work, progress, and failures rather than infer completion from a successful API
response.

Changes carry a revision, and repeating an operation must be safe. Retrying a
creation request returns the same biot; retrying destruction continues cleanup.
The node serializes runtime changes to each biot and never lets a delayed build
or reply supersede a later revision. Long builds do not delay access revocation.
It reconciles recorded intent with actual resources after either program
restarts or their connection is restored.

The persistent data is the checkout and home directory. The runtime is
replaceable. Restarts and rebuilds preserve that data, including dependencies
installed with project package managers. Stopping preserves it too. Biots do not
suspend, and persistence does not provide recovery from lost node storage.
Provisioning initializes the checkout once; reconciliation does not reset user
work to match the original repository revision.

Destroying a biot first removes its managed access, then removes its runtime and
data. If the node is unavailable, cleanup remains pending. The server retains
the destruction record until the node acknowledges cleanup, so reconnecting
cannot resurrect the biot. Permanently retiring a lost node does not constitute
proof that its disks were erased; it cannot rejoin using its old registration.

### Disconnection

An unavailable node is reported as unavailable, not stopped. The server closes
its preview and terminal streams. Once the node detects loss of control-plane
contact, it closes managed SSH sessions, rejects new ones, and stops mediated
credential access. Containers and their background work may continue running.

Loss detection has a finite, configured timeout. Until it expires, the node may
still enforce its last applied permissions. On reconnection it applies current
permissions and lifecycle intent before reopening access. Revocation is
immediate at the server; node enforcement is reported as pending until applied
or access has been closed. Directly supplied secrets cannot be recalled.

This keeps ordinary work alive through a server restart without treating an
indefinitely stale authorization snapshot as current authority.

## Environments

A biot's environment is composed from any number of Nix layers. Personal tools,
team defaults, and project tools are examples of layers, not special categories
with different composition rules. A repository without its own layer can use the
layers selected by its owner.

Layers contribute software and declarative environment configuration, including
named development services. Composition produces one environment description:
the software to make available, its configuration, and the services to start. It
does not execute project startup commands on the node as part of merging
configuration; those commands run within the biot.

Compatible contributions combine. Conflicting contributions fail with a
diagnostic identifying the layers and the conflict. Layer order does not
silently resolve incompatible definitions. The owner or an agent fixes the
inputs and tries again. This checks the declared configuration; it cannot prove
that the resulting applications work correctly together.

Each build records its resolved inputs, including the project configuration
snapshot, so an environment does not change merely because a branch or personal
layer moved. Updating inputs and rebuilding is explicit. Different biots may
therefore use different revisions of the same personal layer.

The node builds an environment before replacing the existing runtime. A
composition or build failure leaves the current runtime and working data
untouched. Replacement may interrupt shells and services; this is a development
environment, not a rolling deployment. Failure to start the replacement is
reported separately from build failure and leaves the persistent data available
for repair. Biot does not roll back changes applications made to that data.

Nodes share immutable Nix store content without giving biots write access to the
shared store. They retain the store paths needed by installed environments,
including stopped biots. The store is for software, not secrets or confidential
working data. Writable checkouts, homes, and package-manager installations stay
private to their biot.

The useful implementation boundary is composition followed by realization:
configuration becomes an environment description, then the node builds and runs
it. Layer authors should not need to know the Podman commands or node filesystem
layout used to realize that description.

## Identity and access

One OIDC provider establishes who a person is, keyed by issuer and subject.
Email can help find a person for sharing, but permissions attach to the resolved
identity. The server owns revocable browser sessions and CLI credentials;
neither carries a permanent copy of its owner's permissions.

The creator owns the biot and controls its lifecycle and sharing. There are two
independent sharing grants: shell access to the biot, and view access to a
particular published port. Shell access permits using the biot's files and
credential grants. It does not confer control-plane ownership.

The browser terminal uses the person's session. SSH uses public keys registered
to their identity. Both enforce the same shell permission, and managed sessions
are associated with the authenticated person so revocation can close them.
Revocation does not undo work or promise to stop detached processes. Biot's
managed SSH admission remains under node control rather than user-editable
project configuration.

Preview applications are outside the control plane's trust boundary. Biot's
browser authentication must work across preview hosts without sharing a
control-plane credential with applications. Preview sessions are scoped to their
host and biot lifetime. The proxy consumes Biot's authentication credentials
instead of forwarding them upstream, and applications cannot set or replace
Biot's authentication state through their responses.

Control-plane mutations must resist requests induced by preview applications,
including when the hosts share a parent domain. Application authentication and
protection of application endpoints remain the application's responsibility.

## Publishing and routing

Publishing binds a hostname to a port inside a specific biot. The destination is
resolved by the node from that biot's current runtime; it is never an arbitrary
host address supplied by a user. Listening-port discovery can help users choose
a port, but grants no access and publishes nothing automatically.

An allocation survives stops, rebuilds, and crashes. Unpublishing disables the
route but retains the allocation; republishing that port restores its URL.
Destroying the biot ends the allocation and invalidates its sessions. A new biot
never inherits an old biot's identity or permissions.

Every preview request is authenticated and checked against the port's current
view grant. The server replaces caller-supplied identity headers with verified
issuer, subject, email, and display name. Services may use that identity or
retain their own authentication. Revocation and unpublishing also close affected
long-lived streams, rather than waiting for the next request.

Authorized visitors can distinguish a stopped biot, an unavailable node, and a
service that is not listening. Other visitors receive the unknown-resource
response. Workloads can read their own published URLs without receiving an API
credential or permission to change publication.

## Isolation and networking

Each biot gets its own container, disjoint host user ID range, writable data,
and process and network namespaces. Shared software is read-only. Resource
controls limit interference between workloads; the operator still provisions
enough capacity for builds and persistent data. Node-side builds also execute
repository-supplied code and need isolation and resource controls, without
access to the node's credentials. Containers share the host kernel and are not a
boundary against determined sandbox escapes.

Biots may initiate outbound connections and receive their responses. This
includes private destinations reachable from the node's network, subject to the
operator's network policy. Biot does not maintain a private-address blocklist.
Private services must enforce their own access controls; being on the same
network as Biot is not evidence of a caller's identity.

Unsolicited inbound access to a biot is restricted to Biot's preview and shell
paths. This also applies to connections attempted by sibling biots: an outbound
allowance at the source does not open an inbound path at the destination. A
service becoming reachable requires explicit publication and authorization, not
merely binding a socket. Necessary node services, such as credential mediation,
expose only the authority granted to the calling biot.

The implementation chooses how to enforce these boundaries. Network namespaces
alone are not an access policy. Biot also does not prevent a workload from using
its permitted outbound access to relay data or establish another access path; it
controls the entry points it provides.

## Git and credentials

Each biot gets an ordinary independent clone from its repository URL. Fetches
and pushes use the upstream directly. There is no node Git cache or intermediate
Git host, and destroying one biot cannot remove objects another checkout needs.
Upstream services enforce branch and repository policies.

Credential grants are selected by the owner independently of environment layers.
Repository configuration cannot acquire credentials. Each grant names the
credential integration and its scope; processes with shell access can use that
scope. Possession of a credential by the owner does not automatically grant it
to every biot.

For supported integrations, the node mediates use while retaining the real
credential outside the biot. The integration authenticates the calling biot,
checks its current grant, and sends credentials only to the intended upstream.
The mechanism can differ by integration, but must preserve those boundaries.
Mediation limits credential exposure, not what an authorized workload can do
with the granted capability or the data it receives.

GitHub integration is optional. It supplies repository-scoped access for normal
Git operations and tools such as `gh`. Other Git hosts and ordinary direct
authentication remain usable. API integrations can similarly mediate access
without placing a long-lived key in the workload.

Owners may supply secrets directly when needed. Biot shows that fact in its
listing and when sharing shell access, since recipients can read those secrets.
An integration must report unsupported clients or failed mediation rather than
silently substituting direct credentials.

Commit signing, when configured, happens at commit time using a dedicated
signing key held outside the biot. Any process in that biot can request a
signature. It establishes use of that signing capability, not human review, and
must not also grant unrelated SSH authentication authority.
