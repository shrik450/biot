# Biot

Biot gives you ephemeral-but-stable secure development environments built on Nix
and podman. Biots are isolated containers with your own tools already inside,
and ports listening in there can get durable, authenticated HTTPS hostnames.
An existing OIDC provider identifies users. Biot controls which environments
and published ports each person can access.

*Status: in progress. The lifecycle and policy core, access, previews, shells,
and the clients exist; credential mediation is planned and not built yet.
[docs/model.md](docs/model.md) is the implementation contract and describes
intended behavior in detail.*

Deployment requirements are in [docs/deployment.md](docs/deployment.md).

> [!NOTE]
> This tool is almost entirely vibe coded. Outside of this README, there is no
> guarantee that anything was written by humans.

## Goals

1. **An isolated biot for each unit of work.** Every biot gets its own
   container, user ID range, filesystem, and network namespace. This separates
   biots from each other and from the host.

2. **An HTTPS hostname for any port, on request.** Biot assigns a hostname to a
   port inside a biot and routes to it, behind the reverse proxy that terminates
   TLS. It publishes a port you name. Discovering a port doesn't publish it.

3. **Identity in the proxy if you need it.** Biot authenticates every visitor
   and passes the verified identity upstream as request headers. Reading them is
   up to your service. You can use them as a substitute for identity in
   work-in-progress services. They don't replace a service's own authentication
   when the service has one.

4. **Granular access control.** Viewing a published port and getting a shell are
   separate permissions on the same biot. Showing someone a preview doesn't give
   them code execution. If there are multiple services in a biot, each can be
   controlled independently.

5. **A hostname per published port, stable for the life of a biot.** Each
   hostname survives restarts, rebuilds, and crashes, so you can reload the same page to access
   the same service over the lifetime of a biot.

6. **Biots cheap enough to leave running.** Biot uses containers so that dozens
   of idle biots fit on one machine. It destroys a biot when the work ends. It
   doesn't suspend or resume them.

7. **Several people on one machine.** Biot ties in with an OpenID Connect (OIDC)
   provider[^1] defines who exists, and per-biot access control lists (ACLs)
   define who reaches what. This shares a machine among people who know each
   other, not among strangers.

\[^1\]: If you don't have one already, I recommend [PocketID](https://pocket-id.org/) for a passkey-only,
self-hostable solution.

8. **Credentials that stay outside the biot.** Biot can mediate API access, so
   you don't need to give your biot real, long lived keys (SSH or API tokens).
   Its optional GitHub integration uses repository-scoped tokens, so a biot
   doesn't have to use an SSH key with access to your full GitHub account.

9. **A control plane that outlives the build machine.** Biot uses a server-node
   architecture that mean you can have node machines that are outside the
   server. Identity, ACLs, and hostnames, and runs apart from the node that runs
   containers. It is deliberately simpler than a full scheduler or orchestration
   engine like Kubernetes.

## Non-goals

1. **Not a tunnel.** Biot assumes a network already connects your browser, the
   server, and the nodes. Bring your own: a mesh virtual private network (VPN),
   a WireGuard tunnel you run, or plain internet routing you trust. Biot manages
   access, not reachability.

2. **Not a TLS terminator.** Biot doesn't terminate TLS at the edge or manage
   public certificates. You put a reverse proxy in front of it, holding a
   wildcard certificate for your preview hostnames. It needs two routes that
   never change: the control hostname and the preview wildcard, both to one
   Biot port. Any reverse proxy will do.

3. **Not a sandbox against a determined attacker.** Containers stop accidents,
   mistakes, and careless dependencies, but Biot's threat model doesn't account
   for determined attackers attempting a sandbox escape. If that's a real
   concern, Biot is not for you.

4. **Not a deployment platform.** Biot runs biots for development. It doesn't
   build production artifacts, schedule workloads, or manage anything outside
   your development loop.

5. **Not a public sharing service.** The preview ingress is reachable only from
   the network you put Biot on. If you want to expose a preview, either make
   your site reachable from the internet, or put a tunnel service in front of
   it.

6. **Not a front end for services you already run.** You can't point Biot at an
   arbitrary port on the host. Every published port lives inside a biot that
   Biot created. This is the rule that stops Biot from re-exposing an existing
   service under a weaker ACL.

7. **Not an orchestrator.** One server, a few nodes and SQLite. No bin packing,
   no autoscaling, and no high availability.

8. **Not an identity provider.** Biot holds sessions and ACLs. It doesn't hold
   passwords, user records, or a registration flow.

9. **Not an editor.** Biot's web UI gives you a Ghostty Web-backed shell into a
   biot that already contains your tools, and you can SSH into them through the
   Biot server. What you do beyond that is up to you!

## How it works

```sh
$ biot login https://biot.company.test
Open this URL to create or copy a bearer token:
https://biot.company.test/account
Bearer token:
Logged in as 8f3c1e90-5a7d-4b21-9e64-2c8a0f1d3b57.
$ biot create --repo https://github.com/me/app.git --name checkout-flow
biot ready: checkout-flow
$ biot publish checkout-flow 3000
https://patient-owl-k7m2.env.test
$ biot share checkout-flow --port 3000 --to alice@company.test
```

You can also do these through the web UI. Both clients use the same lifecycle
and access rules.

Each flow below walks left to right, and every column is one component. Read a
row to see which component does what.

```text
inbound         you             edge   server          node            biot
────────────────────────────────────────────────────────────────────────────
create a biot   biot create ─────────▶ pick a node ──▶ build, clone ─▶ start
publish a port  biot publish ────────▶ name a host
open a preview  browser ──────▶ TLS ─▶ session, ACL ─▶ open stream ──▶ serve
get a shell     ssh ─────────────────▶ key, ACL ─────▶ open stream ──▶ shell
destroy a biot  biot destroy ────────▶ release name ─▶ remove ───────▶ gone
```

Every biot runs a small Biot agent. The node reaches it through a private
socket, and the agent connects to the port you published or starts your shell.
Nothing inside a biot listens on the host, and no biot can reach another.

Biot will mediate credential use on the node. With an integration enabled, the
node holds the real credentials. These integrations are planned and not built yet:

```text
outbound             biot            node                       out
─────────────────────────────────────────────────────────────────────────
git push             git push ─────▶ inject a repo token ─────▶ GitHub
open a pull request  gh pr create ─▶ inject a repo token ─────▶ GitHub
call a model API     API client ───▶ authorize with real key ─▶ Anthropic
sign a commit        git commit ───▶ sign with a dedicated key
```

Each integration will mediate only the access you grant. The first release
accepts scoped credentials for private source fetching. You can also supply a
real key with `--secret`; `biot list` marks biots given secrets this way.
Ordinary outbound connections, such as package downloads, need no credential
integration.

## Decisions

**Implementation:** Elixir/OTP powers the server and node, Phoenix LiveView
provides the web UI, and Go provides the CLI. Nix owns environment composition
and builds.

| Area        | Contract                                                       |
| ----------- | -------------------------------------------------------------- |
| Lifecycle   | the server records intent; assigned nodes reconcile actual state |
| Isolation   | Podman containers with separate user ID ranges and writable data |
| Software    | any number of Nix layers compose, or report conflicts            |
| Access      | separate shell and per-port view grants, tied to OIDC identities |
| Publishing  | explicit ports get stable hostnames through the server          |
| Credentials | runtime secrets and private source credentials; runtime mediation planned |
| Git         | independent clones using ordinary upstream URLs                 |
| Network     | allow outbound connections; control entry through Biot          |
| Node trust  | encrypted, mutually authenticated server–node communication      |

The [implementation model](docs/model.md) defines these boundaries and their
behavior during changes and failures. Connectivity and edge TLS remain the operator's
responsibility.
