# Deploying Biot

Biot runs rootless. The server runs as an ordinary service user, and the node runs Podman as an
ordinary service user after a one-time host setup for subordinate IDs and the rootless container
runtime. No Biot release needs `sudo`, `--privileged`, or a uid-0 check.

This guide covers the host contract for the `server` and `node` releases. It assumes that the
server and node can reach each other over a network you operate, that an OIDC provider is
available, and that the operator provisions the mutual-TLS material and node registration used by
the control link. The operator enrollment and certificate commands are described in the
[deployment contract](model.md#deployment-contract). Day-two operations are out of scope, except
for the procedure that starts a Biot which will not run; the last section names the rest.

## Local one-host smoke run

The repository includes one launcher that reuses `dev/stack.exs` for the server and its local OIDC
provider, then starts a real node against the same loopback control listener:

```sh
nix develop --command bash dev/local.sh
```

It creates certificates, enrollment, SQLite state, and node data under `.work/`, removes them after
a clean stop, and preserves the run directory and logs after a failed start. The launcher runs the
full host path, including the rootless Podman/Nix worker. Node startup gets twenty minutes and each
Nix worker is capped at twenty minutes; a timeout preserves the run directory and its diagnostics
instead of retrying indefinitely.

## Overview

The path from an empty host to a first Biot, in the order to do it. `deploy/install-server.sh` and
`deploy/install-node.sh` perform the two host setups and are safe to run again.

1. **Before you start**, have a server host and a node host (they may be the same machine), the
   control hostname and publication domain you will serve, a TLS certificate and DNS records
   covering both, and an OIDC provider you control. [Choose the listeners and the
   edge](#choose-the-listeners-and-the-edge) gives the certificate and DNS requirements.
2. **Register Biot with your OIDC provider** and note its issuer URL, client ID, and client
   secret. See [Register Biot with your OIDC provider](#register-biot-with-your-oidc-provider).
3. **Build the releases** from a checkout with the pinned toolchain. See
   [Build the releases](#build-the-releases).
4. **Create the control-link authority and issue the certificates**: the authority, the server
   certificate, and one certificate per node. See [Server](#server).
5. **Write the node enrollment file** with `mix biot.enroll`, which records each node's certificate
   fingerprint and capacity. See [Server](#server).
6. **Run the server**, with `deploy/install-server.sh` or the compose file in
   [docker/server/README.md](../docker/server/README.md), which builds its own image. See
   [Server](#server).
7. **Run the node** with `deploy/install-node.sh`. See [Node](#node).
8. **Sign in and create a bearer token** for the CLI. See
   [Sign in and create a bearer token](#sign-in-and-create-a-bearer-token).
9. **Create your first Biot** and watch it build. See [Check the node](#check-the-node).

[Local one-host smoke run](#local-one-host-smoke-run) is a development shortcut that runs the same
host path on one machine with a local OIDC provider.

## Build the releases

Build both releases from a checkout on the machine that runs them, or on a machine with the same
architecture. This needs the pinned Elixir, OTP, and the project's dependencies; it does not need
root.

The repository pins its toolchain in `flake.nix`: **Erlang 28.5**, **Elixir 1.20.4 with OTP 28**,
and **Go 1.26**. Install [Nix](https://nixos.org/download/) with flakes enabled, then run the
commands in the checkout from the flake's development shell. `nix develop` enters it interactively,
and `nix develop --command` runs one command inside it:

```sh
nix develop --command mix deps.get
MIX_ENV=prod nix develop --command mix release server
MIX_ENV=prod nix develop --command mix release node
```

The server build also compiles and digests the web assets; that is part of the release step, not a
separate one. Each command ends with:

```
Release created at _build/prod/rel/server
```

or the same line for `_build/prod/rel/node`. Add `--overwrite` to either command to rebuild over an
existing release directory.

The releases land at `_build/prod/rel/server` and `_build/prod/rel/node`. A release directory is
self-contained — `erts-<vsn>/`, `lib/`, `releases/`, and `bin/<name>` — and its scripts resolve
their own location, so the directory can be copied to the service location and run from there.
`bin/<name> version` prints the release and version without starting anything.

The commands every release provides:

```text
start          Starts the system
start_iex      Starts the system with IEx attached
daemon         Starts the system as a daemon
daemon_iex     Starts the system as a daemon with IEx attached
eval "EXPR"    Executes the given expression on a new, non-booted system
rpc "EXPR"     Executes the given expression remotely on the running system
remote         Connects to the running system via a remote shell
restart        Restarts the running system via a remote command
stop           Stops the running system via a remote command
pid            Prints the operating system PID of the running system via a remote command
version        Prints the release name and version to be booted
```

`config/releases/server.exs` and `config/releases/node.exs` are copied into the release as
`releases/<vsn>/runtime.exs` and read at boot, before the application serves anything. A missing or
invalid setting stops the release with the name of the variable:

```
ERROR! Config provider Config.Reader failed with:
** (RuntimeError) environment variable PHX_HOST is missing
```

That is a configuration failure, not an application crash; fix the setting and start again.

## Register Biot with your OIDC provider

Biot is an OIDC client and not an identity provider: a person exists only as the `(issuer, subject)`
pair the provider hands it. Register one client with your provider and give the server its settings;
nothing else in Biot is an identity source.

### What to register

| Setting | Value |
| --- | --- |
| Issuer | The provider's HTTPS issuer URL, the base of its `/.well-known/openid-configuration` |
| Redirect URI (callback URL) | `https://<PHX_HOST>/login/callback`, exactly, with no trailing slash |
| Scopes | `openid email profile` |
| Client type | Confidential; the server requires a client secret |
| Token-endpoint authentication | A client-secret method; see below |

The redirect URI comes from `Login.Settings.parse/4`, which builds
`https://<control_host>/login/callback` from `PHX_HOST`. The server sends exactly that value in the
authorization request, so the provider must have it registered verbatim.

The server asks for `openid`, `email`, and `profile` and no other scope, and it uses neither the
userinfo endpoint nor a refresh token. `openid` is what asks for the ID token; `email` and `profile`
are what carry the `email` and `name` claims.

The grant is the authorization code grant with PKCE. The server sends a `code_challenge` and
`require_pkce`, using S256 when the provider advertises it and `plain` otherwise, and sends the
verifier on the token request. The provider's discovery document must advertise
`code_challenge_methods_supported`, or the server cannot start a login at all.

The client is confidential: `Login.Settings.parse/4` requires a non-empty client secret, and the
server sends the client id and secret to the token endpoint. Biot does not choose the
authentication method; `oidcc` picks the first method the provider advertises from its own
preference order (`private_key_jwt`, `tls_client_auth`, `client_secret_jwt`, `client_secret_post`,
`client_secret_basic`, `none`) and falls through when it cannot perform one. Biot supplies no JWKS
and no client certificate, so register the client with a secret and let the provider offer
`client_secret_post`, `client_secret_basic`, or `client_secret_jwt`; a provider that advertises
only `private_key_jwt` or `tls_client_auth` has nothing Biot can authenticate with.

### What Biot does with the claims

Biot reads the ID token's claims and does not call userinfo. `Login.identity_claims/1` takes four:

| Claim | Required | What Biot does with it |
| --- | --- | --- |
| `iss` | yes | Half of the principal's identity. |
| `sub` | yes | Half of the principal's identity. |
| `email` | no | Stored as the principal's last-seen email. `biot share --to EMAIL` resolves a person by it, and sign-in prints it first. |
| `name` | no | Stored as the principal's last-seen name. Sign-in prints it when there is no email, and the account page shows it. |

`Principals.identify/3` finds the principal by `(iss, sub)` and inserts one on first sign-in, with
the email and name it was given. Every later sign-in overwrites both, so they are "last seen" and
not authoritative. A different `sub` from the same issuer is a different person, and principals are
never deleted, so a person's row and its ID outlive the provider's records.

Omitting `email` or `name` is allowed; omitting `iss` or `sub` is not:

- An absent `email` or `name` becomes `nil`. Sign-in still succeeds; the CLI falls back from the
  email to the name and then to the principal's ID, and no one can be resolved by an absent email.
- A missing, non-string, or otherwise unparseable `iss` or `sub` fails the login with
  `:invalid_claims`, and the browser gets the generic unauthenticated response.
- A present but non-string `email` or `name` fails the same way.

`biot share --to EMAIL` resolves only a unique match on the last-seen email, so two principals that
last signed in with the same address resolve to neither.

Biot never calls userinfo, so `email` and `name` have to be claims of the **ID token**. A provider
that exposes them only at the userinfo endpoint still signs a person in, but Biot stores no email
or name for them.

### What the server refuses at boot

`config/releases/server.exs` reads the settings before the server serves anything, and
`Login.Settings.parse/4` refuses:

- A missing `BIOT_OIDC_ISSUER`, `BIOT_OIDC_CLIENT_ID`, or `BIOT_OIDC_CLIENT_SECRET`, which stops the
  release with `environment variable ... is missing`.
- An issuer that is not HTTPS (`:insecure_issuer`), reported as `BIOT_OIDC_ISSUER must be an https
  URL`. A provider you are testing over plain HTTP, including one on loopback, is refused; the
  release has no plain-HTTP mode.
- An issuer that is not a URL with a host (`:invalid_issuer`).
- An empty client id or secret (`:empty_client_credentials`).

The same file parses `PHX_HOST` and `BIOT_SERVER_PUBLICATION_DOMAIN`: both must be lowercase DNS
names, and the control host must not be the publication domain or a name under it.

### Worked example: PocketID

[PocketID](https://pocket-id.org/) is the self-hostable provider the project's README recommends. In
its admin UI (or by its API; the field names are PocketID's, not Biot's), create an OIDC client and
set:

- The callback or redirect URL to `https://biot.example.com/login/callback`, with your `PHX_HOST`.
- The scopes to include `openid`, `email`, and `profile`.
- A client secret, so the client is confidential rather than public.

Then give the server the three values it reads:

```sh
BIOT_OIDC_ISSUER=https://id.example.com
BIOT_OIDC_CLIENT_ID=<the client ID PocketID shows>
BIOT_OIDC_CLIENT_SECRET=<the client secret PocketID shows>
```

The installer takes the issuer and client id as `--oidc-issuer` and `--oidc-client-id`, and the
secret through `--oidc-client-secret-file` or `BIOT_OIDC_CLIENT_SECRET`. The first successful login
creates the principal; there is no administrator account and no registration flow.

### Facts the provider decides, not Biot

Which token-endpoint authentication method is used, and whether `email` and `name` appear in the ID
token rather than only at userinfo, are the provider's behavior. Biot's side is fixed and small: one
redirect URI built from `PHX_HOST`, three scopes, and four claims.

## Server

The server's runtime needs no root; only the one-time setup steps marked **Root.** do. It needs an
unprivileged service account, ordinary ownership of its database and key material, and listeners on
ports the service account can bind.

There are two ways to run it:

- **The compose file**, documented in [docker/server/README.md](../docker/server/README.md). It
  builds the image and starts one server with a small environment file, and suits trying the
  server, a demo, or one host with no systemd. It is **not a production deployment**: it publishes
  plain HTTP and does not terminate TLS.
- **A release under systemd**, this section. It suits a long-lived server behind the operator's
  edge. [deploy/install-server.sh](../deploy/install-server.sh) performs the host setup, and
  [deploy/install-node.sh](../deploy/install-node.sh) does the same for a node.

### Run the installer

Build the server release first, as [Build the releases](#build-the-releases) describes. Two pieces
of material are the operator's to create, because both need the control-link authority:

**The control-link certificates.** The authority is created once and never replaced, and its
private key stays with the operator:

```sh
nix develop --command mix biot.certs authority DIR
nix develop --command mix biot.certs server DIR
nix develop --command mix biot.certs node DIR biot-node-1
```

Copy `ca.pem`, `server-cert.pem`, and `server-key.pem` to the server's certificate directory.
`ca-key.pem` never leaves `DIR` and never goes to a node. The server's leaf is valid for **395 days
(about 13 months)** and the authority for 25 years; renewing a leaf reuses its key, so its
fingerprint does not change and every node pin stays valid.

**The node enrollment file**, `BIOT_NODE_REGISTRATIONS`. Write it with `mix biot.enroll` instead of
by hand: the task validates the entry with the same schema the server parses, so it cannot write a
file the server rejects, and it is safe to run again for the next node.

```sh
nix develop --command mix biot.enroll --file node-registrations.json \
  --name biot-node-1 --certs-dir DIR \
  --registration-id <the node's BIOT_NODE_REGISTRATION_ID> --max-biots 4
```

`--name` reads `DIR/node-biot-node-1-cert.pem` and computes the fingerprint, or give the value
`mix biot.certs node` printed with `--fingerprint`. Re-running the task for the same registration
updates that entry and keeps its `node_id`.

Then run the installer as root on the server host:

```sh
sudo deploy/install-server.sh \
  --control-host biot.example.com \
  --publication-domain preview.example.com \
  --oidc-issuer https://id.example.com \
  --oidc-client-id biot \
  --oidc-client-secret-file /root/biot-oidc-secret \
  --registrations /etc/biot/node-registrations.json
```

It reads the OIDC client secret from `--oidc-client-secret-file` or `BIOT_OIDC_CLIENT_SECRET`,
never from the command line, so it does not reach the process list or the shell history.

Run it with `--check` first; that makes no changes and prints one line per precondition, naming the
file or command to fix for a failure. A `BLOCK` line stops the install. A `todo` line is work the
installer will do, such as creating the account or generating the SSH host key, and `--check` exits
non-zero only when a `BLOCK` remains. `--help` lists every path and override.

The installer writes these, and prints them when it finishes:

| What | Default |
| --- | --- |
| Release directory | `/opt/biot/server` |
| Data directory and database | `/var/lib/biot`, database `/var/lib/biot/server.sqlite3` |
| Certificate directory | `/etc/biot/certs` |
| SSH host key | `/etc/biot/ssh-host-key`, generated when missing |
| Release environment | `/etc/biot/server.env`, mode 0600, owned by the service account |
| Unit file to read and edit | `/etc/biot/biot-server.service` |
| Installed unit | `/etc/systemd/system/biot-server.service` |

A second run is safe: it fills in what is missing and leaves the account, the paths, and the
existing environment and unit files alone. `--force-env` and `--force-unit` regenerate those two
files. The installer gives the service account read access to the certificates and the enrollment
file, and generates the SSH host key when it is missing. Without `--registrations` the server
accepts no node.

### Choose the listeners and the edge

All three server listeners may be above 1024. The HTTP listener is the reverse-proxy target; the
control listener is for nodes and streams; the SSH listener is reached by SSH clients directly.

| Setting | Purpose | Port rule |
| --- | --- | --- |
| `PORT` (default `4000`) | Phoenix HTTP endpoint for the web UI and preview edge | Any port above 1024 |
| `BIOT_CONTROL_PORT` (default `4443`) | Mutually authenticated node control and stream connections | Any port above 1024; the node's `BIOT_SERVER_PORT` must match |
| `BIOT_SSH_PORT` (required; no default) | SSH entry point reported to CLI users | Any port above 1024 |

Put a reverse proxy in front of `PORT` when serving the control host and preview hostnames. The
proxy terminates public TLS, forwards the unchanged `Host`, replaces forwarded-client headers with
its own values, supports WebSocket upgrades, and does not buffer streamed responses. SSH is not
proxied through that HTTP edge.

#### The edge proxy: certificate, DNS, and an example

The edge needs one TLS certificate that covers **two names**: the control host (`PHX_HOST`) and
`*.<BIOT_SERVER_PUBLICATION_DOMAIN>`. A certificate whose subject names include both, or a single
`*.example.com` wildcard when the control host and the publication domain both live under
`example.com`, satisfies this. Without the wildcard name, every preview hostname fails TLS in the
browser and no preview can be opened.

DNS must match. The control hostname needs an ordinary record, and
`*.<BIOT_SERVER_PUBLICATION_DOMAIN>` needs a **wildcard record**, both pointing at the proxy.
Preview hostnames are generated per published port, so there is no fixed list of names to create;
the wildcard record is what lets any of them reach the edge.

Any proxy will do. This example is for **nginx**; it terminates TLS for both names, forwards the
unchanged `Host` to the server's `PORT`, replaces the client address, passes WebSocket upgrades,
and turns response buffering off so streamed preview responses are not held back. It assumes the
control host is `biot.example.com` and the publication domain is `preview.example.com`, so
`PHX_HOST=biot.example.com` and `BIOT_SERVER_PUBLICATION_DOMAIN=preview.example.com`; substitute
yours.

```nginx
# In the http block. WebSocket upgrades are idle for longer than nginx's 60s default read timeout,
# so the upstream timeout is raised below as well.
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 443 ssl;
    # Both names in one block; the certificate must cover both.
    server_name biot.example.com *.preview.example.com;

    ssl_certificate     /etc/letsencrypt/live/biot.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/biot.example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:4000;   # the server's PORT
        proxy_http_version 1.1;

        # Host unchanged, so the server can tell the control host from a preview host.
        proxy_set_header Host $host;
        # Replace, not append, so a client cannot forge its own forwarded address.
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;

        # Preview responses and request bodies stream; do not spool them.
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
    }
}
```

This check needs the server running ([The systemd unit and checks](#the-systemd-unit-and-checks)).
It proves the certificate, the DNS, and the forwarding all work:

```sh
curl -sS -o /dev/null -w '%{http_code}\n' https://biot.example.com/
curl -sS -o /dev/null -w '%{http_code}\n' https://probe.preview.example.com/
```

The first prints `200` — the landing page, for a request with no session cookie (a signed-in
browser is redirected to `/biots` instead). The second prints `404` — the preview not-found page,
because no publication uses that hostname. The `404` is the point: it means TLS succeeded, the
wildcard DNS resolved, and the edge reached Biot. When a check fails, the failure is the diagnosis:
a TLS error means the certificate does not cover the name; `NXDOMAIN` means the wildcard DNS record
is missing; `502` means the edge cannot reach the server's `PORT`.

For public ports 443 or 22, either forward those ports from a proxy or load balancer to the
unprivileged listeners, or grant only `CAP_NET_BIND_SERVICE` to the server service. The installer
adds that capability to the unit automatically when a listener is below 1024. It is not a reason to
run the server as root.

### The release environment

The installer writes every required setting into the environment file. Edit that file, or re-run
with `--force-env` after changing the installer's flags, to set an optional one. The release
validates these values before it serves requests. `PHX_HOST` and
`BIOT_SERVER_PUBLICATION_DOMAIN` must be lowercase DNS names, and the control host must not be the
publication domain or a name below it.

| Variable | What it supplies | Where it comes from |
| --- | --- | --- |
| `PHX_HOST` | Control hostname used by the browser login flow | `--control-host`; a DNS name you point at the edge |
| `BIOT_SERVER_PUBLICATION_DOMAIN` | Suffix under which published preview hostnames are created | `--publication-domain`; `PHX_HOST` must not be under it |
| `SECRET_KEY_BASE` | Phoenix signing and encryption key | Generated on first install, then reused so sessions survive |
| `BIOT_OIDC_ISSUER` | The OIDC provider's HTTPS issuer URL | `--oidc-issuer`; the provider's app registration |
| `BIOT_OIDC_CLIENT_ID`, `BIOT_OIDC_CLIENT_SECRET` | The server's OIDC client credentials | `--oidc-client-id`, and the secret file or env variable |
| `BIOT_SERVER_DATABASE` | Absolute path to the SQLite database | `--database`, default `/var/lib/biot/server.sqlite3` |
| `BIOT_SSH_ADVERTISED_HOST` | Hostname or address printed for SSH clients | `--ssh-advertised-host`, default the control host |
| `BIOT_SSH_PORT` | SSH listener port | `--ssh-port` |
| `BIOT_SSH_HOST_KEY_FILE` | SSH host-key file | `--ssh-host-key`; generated when missing |
| `BIOT_CONTROL_CERTFILE`, `BIOT_CONTROL_KEYFILE`, `BIOT_CONTROL_CACERTFILE` | Server certificate, private key, and CA for node control TLS | The certificate material you copied into the certificate directory |
| `BIOT_NODE_REGISTRATIONS` | Operator enrollment file for the nodes this server accepts | `--registrations` |
| `BIOT_SESSION_LIFETIME_HOURS` (default `168`) | How long a signed-in browser session stays valid | Optional; 168 hours is 7 days |
| `BIOT_CREDENTIAL_MAX_LIFETIME_DAYS` (default `90`) | The longest lifetime a person may give a bearer token | Optional; 90 days |
| `BIOT_AUTH_CHECK_INTERVAL_MS` (default `60000`) | How often the server rechecks every live browser, credential, and SSH proof | Optional; a shorter interval revokes a disabled person sooner, at the cost of more database reads |
| `BIOT_LOG_LEVEL` (default `info`) | Release log level | Optional; one of `debug`, `info`, `notice`, `warning`, `error`, `critical`, `alert`, or `emergency`. Any other value stops the release, and its message lists the accepted levels |

`PORT` and `BIOT_CONTROL_PORT` have the defaults shown above. `BIOT_DEFAULT_NODE_ID` can select a
default node; leave it unset when the server should require an explicit node choice. The optional
`BIOT_DISABLED_PRINCIPALS` and `BIOT_TRUSTED_EDGE_PEERS` files/settings are for operators who use
those policies at the edge.

The enrollment file is a JSON list. Each entry is one node:

```json
[
  {
    "node_id": "<canonical UUID you choose for this node>",
    "registration_id": "<canonical UUID; the node sets BIOT_NODE_REGISTRATION_ID to it>",
    "peer_identity": "<the node certificate fingerprint from mix biot.certs node>",
    "max_biots": 4,
    "status": "enabled"
  }
]
```

`node_id` is how the server assigns Biots to this node and how the node list identifies it.
`peer_identity` is the lowercase SHA-256 fingerprint of the node certificate's public key, which
is the `fingerprint` `mix biot.certs node` prints. `status` is `enabled`, `disabled`, `retired`, or
`abandoned`. `mix biot.enroll` writes these entries; the server imports the file at boot, and
reimports it on a running server without a restart:

```sh
/opt/biot/server/bin/server rpc "Biot.Server.Nodes.reload()"
```

The server advertises every SSH host key pinned at daemon startup through the authenticated
deployment API. `biot ssh` uses that HTTPS response to create a temporary OpenSSH `known_hosts`
file and refuses any key that is not advertised; it never asks a person to accept an unchecked key.
The response includes each key's type, public-key text, and `SHA256:` fingerprint. The public-key
text is needed to construct the native `known_hosts` entry; it is not secret material.

When SSH is disabled because no host-key file is configured (as may be the case in a development
environment), the deployment response has no `host_keys` entry. `biot ssh` reports that the server
has no SSH host key configured and names `BIOT_SSH_HOST_KEY_FILE`; it does not fall through to a
connection-refused error.

### SSH host-key rotation

The SSH callback chooses one key for each key type. A rotation can therefore overlap keys only when
the old and new keys have different types (for example, `ssh-ed25519` and
`ecdsa-sha2-nistp256`). During that transition, configure both keys, restart the server, and wait
for the deployment response to advertise both before removing the old key. The server rejects a
configuration containing two keys of the same type, because it could advertise a key that the SSH
daemon cannot select.

`BIOT_SSH_HOST_KEY_FILE` names **one file**, and both private keys go in it, one after the other.
Concatenate them:

```sh
cat /etc/biot/ssh-host-key-old /etc/biot/ssh-host-key-new > /etc/biot/ssh-host-key
```

The daemon decodes the whole file into a list, which is how it sees two keys at all; there is no
second path setting. Confirm the result before restarting, with the installer's own check:

```sh
sudo ssh-keygen -lf /etc/biot/ssh-host-key
```

prints one line per key, one per type. Two lines of the same type mean the server will refuse to
start.

Same-type replacement is not a supported transparent rotation: the callback cannot serve both
keys, so an old advertisement followed by a new key is indistinguishable from an attack. Choose a
different key type for a planned rotation. Any same-type replacement is deliberately refused by
clients until the operator has investigated and made the new advertisement consistent; an
unexpected key change has the same safe refusal and is never silently accepted as a rotation.

### The systemd unit and checks

The installer writes the unit to `/etc/biot/biot-server.service` for you to read and edit, installs
it, reloads systemd, and starts and enables it. It is a system service with `User=biot`, and it
carries `AmbientCapabilities=CAP_NET_BIND_SERVICE` and `CapabilityBoundingSet=CAP_NET_BIND_SERVICE`
only when one of the listeners is below 1024. The unit it writes is:

```ini
[Unit]
Description=Biot server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=biot
Group=biot
WorkingDirectory=/opt/biot/server
EnvironmentFile=/etc/biot/server.env
ExecStart=/opt/biot/server/bin/server start
ExecStop=/opt/biot/server/bin/server stop
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

`bin/server start` runs in the foreground, which is what `Type=simple` expects. `ExecStop` works
because a release names a local Erlang node by default, which is what `bin/server stop` talks to.

Checks, and the output that means it worked:

```sh
systemctl is-active biot-server
```

prints `active`. `journalctl -u biot-server -f` follows the log. The release writes to standard
output and error, so the journal is the log; there is no log file. `journalctl -u biot-server -r`
reads it newest-first.

The release's own commands check the running system:

```sh
/opt/biot/server/bin/server pid
```

prints the operating system process id. `bin/server remote` opens a shell on the running server,
and `bin/server rpc "EXPR"` runs one expression on it.

```sh
ss -ltn | grep -E ':(4000|4443|2222)\b'
```

prints one `LISTEN` line per configured listener, using the ports you set for `PORT`,
`BIOT_CONTROL_PORT`, and `BIOT_SSH_PORT`.

A release with a bad setting never reaches this point; it stops with the
`ERROR! Config provider Config.Reader failed with` block from [Build the releases](#build-the-releases),
naming the variable.

The image's health endpoint answers the same way on a release: `curl -sS http://127.0.0.1:4000/health`
prints `{"status":"ok"}` once the database is reachable.

Then check the service from outside: the HTTP endpoint answers through the reverse proxy and the
OIDC redirect returns to `https://<PHX_HOST>/login/callback`; the control port is reachable from
each node host; the SSH advertised host and port are reachable by an SSH client.

Start each node only after its entry is in the enrollment file and its certificate is in place. The
server imports the file at boot, or with the `reload` command above; an unregistered node cannot
become ready.

## Sign in and create a bearer token

The server is up. Before anyone uses the CLI, a person has to sign in and mint the token it uses.
There is no administrator account: every authenticated person is a principal, and whoever creates
a Biot owns it.

1. Open `https://<PHX_HOST>/` in a browser and follow the `sign in` link. It sends you to the OIDC
   provider and back to `https://<PHX_HOST>/login/callback`; the first successful login creates the
   principal.
2. Open `https://<PHX_HOST>/account`. Under **bearer credentials**, give the token a label and an
   expiry, then choose **create token**. The clear token is shown **once**; copy it then, because
   the server keeps only its digest and cannot show it again.
3. On the machine where you will run `biot`, save the token:

   ```sh
   biot login https://<PHX_HOST>
   ```

   It prints the account URL, offers to open it, and prompts `Bearer token:` without echoing what
   you paste. On success it prints who it authenticated as:

   ```text
   Open this URL to create or copy a bearer token:
   https://biot.example.com/account
   Bearer token:
   Logged in as you@example.com.
   ```

   What follows `Logged in as` is the principal's email when the OIDC token carries one, then its
   name, and the principal UUID if it carries neither. A provider that returns no email and no name
   therefore prints `Logged in as <principal id>.`; all three forms name the same account.

   The server URL and token are saved in `$XDG_CONFIG_HOME/biot/config.json`, mode 0600, so later
   `biot` commands need no arguments. A refused token prints `The token was not accepted. Check the
   token and run biot login again.` and saves nothing, so you can simply run it again.
4. Add an SSH public key on the same page, or with `biot ssh-key add FILE`, before anyone uses
   `biot ssh` or plain `ssh`.

The account page also lists the server's SSH host keys; that is what the fingerprint check in the
server section compares against. A bearer token acts as its principal until it expires or is
revoked, so treat it as a password and revoke it from this page when it is no longer needed. Until
a token is saved, every other `biot` command stops with `you are not logged in; run biot login`.

## Node

The node runs rootless Podman as an ordinary service account. `deploy/install-node.sh` performs the
whole one-time host setup in one idempotent command: it checks the host, creates the service
account and its paths, reads the subordinate UID/GID range the host assigned, copies the node
release, pulls the pinned builder image, writes the release environment, and installs and starts
the systemd unit. What follows is the reference for the values you supply and the choices the
installer makes.

### Run the installer

Build the node release first, as [Build the releases](#build-the-releases) describes. Then issue
the node's control-link certificate from the same authority the server uses. The authority's
private key never goes to a node, so run the command where the authority lives and copy `ca.pem`
and the node's certificate and key to the node's certificate directory:

```sh
nix develop --command mix biot.certs node <authority-directory> biot-node-1
```

Then run the installer as root on the node host, naming this node and the server it trusts:

```sh
sudo deploy/install-node.sh \
  --node-name biot-node-1 \
  --server-host biot.example.com \
  --server-fingerprint <the fingerprint mix biot.certs server printed> \
  --registration-id <this node's registration_id from the server enrollment file>
```

Run it with `--check` first; that makes no changes and prints one line per precondition, naming the
command or file to fix for a failure. A `BLOCK` line stops the install. A `todo` line is work the
installer itself will do, such as creating the account or its subordinate range, and `--check`
exits non-zero only when a `BLOCK` remains. `--help` lists every path and override.

The installer writes these, and prints them when it finishes:

| What | Default |
| --- | --- |
| Release directory | `/opt/biot/node` |
| Data root | `/var/lib/biot/node` |
| Runtime root | `/run/biot-node`, created by the unit's `RuntimeDirectory=` and cleared on stop |
| Certificate directory | `/etc/biot/certs` |
| Release environment | `/etc/biot/node.env`, mode 0600, owned by the service account |
| Unit file to read and edit | `/etc/biot/biot-node.service` |
| Installed unit | `/etc/systemd/system/biot-node.service` |

A second run is safe: it fills in what is missing and leaves the account, the paths, the range, and
the existing environment and unit files alone. `--force-env` and `--force-unit` regenerate those
two files after you change the values, so the unit an operator edited is never replaced by
surprise.

The installer assumes the node's certificate, key, and the CA are already in the certificate
directory, and gives the service account read access to them. It never issues them itself.

The runtime root is separate from the data root, and short, because it holds one Unix socket per
running Biot and Linux caps a socket path at 108 bytes including its terminating NUL. Put the data
root wherever the disk is, however deep; keep `--runtime-root` under `/run` so systemd creates and
clears it. The installer refuses a runtime root too long to hold a socket path, and so does the
node at boot.

### Host prerequisites

The installer checks these before it changes anything, and a failed check names the missing package
or command. Install them with the host package manager first.

| Requirement | Why it is needed |
| --- | --- |
| Podman | Starts the allocation and runtime containers without a daemon or root |
| `newuidmap` and `newgidmap` (normally the `uidmap` package) | Applies the subordinate UID/GID maps |
| `fuse-overlayfs` or an in-kernel overlay driver | Gives rootless Podman a writable container storage driver |
| `slirp4netns` or `pasta` | Provides rootless container networking where needed |
| Enabled user namespaces | Lets Podman create the rootless and per-Biot mappings |
| cgroup v2 with usable delegation | Lets the service account manage its containers |

### The subordinate UID/GID range

The node gives each Biot a slice of the service account's subordinate UID/GID range and passes that
slice to Podman. **The node's range is the host's range**: the numbers the node is configured with
are host subordinate IDs, so the node's base has to be the start the host assigned.

The installer reads the start from the service account's `/etc/subuid` entry and writes it as
`BIOT_NODE_UID_RANGE_BASE`. There is no flag to set the base, because a base that disagrees with
the host is the failure this exists to prevent: the node boots, and then every ownership check and
every stream fails with `agent_unreachable` at stream time, not at boot. When the account has no
entry, the installer adds one and reads back what the host assigned.

The two rules are:

```text
BIOT_NODE_UID_RANGE_BASE == the host's subuid start
subordinate count        >= BIOT_NODE_UID_RANGE_LIMIT - BIOT_NODE_UID_RANGE_BASE
```

| Setting | Meaning |
| --- | --- |
| `BIOT_NODE_UID_RANGE_BASE` (default `100000`) | The host's subordinate start; must match `/etc/subuid` |
| `BIOT_NODE_UID_RANGE_COUNT` (default `1024`) | IDs reserved by each Biot |
| `BIOT_NODE_UID_RANGE_LIMIT` (default `BASE + 65536`) | Exclusive end of the node's span; must not exceed `BASE + <host count>` |

If `LIMIT - BASE` is larger than the host's subordinate count, allocation or worker startup fails
with an insufficient-UID error; increase the host range or reduce the node's span. The node maps
its UID and GID through the one base, so `/etc/subuid` and `/etc/subgid` must give the service
account the same start; the installer refuses to continue when they do not.

### The release environment

The installer writes every required setting into the environment file. Edit that file, or re-run
with `--force-env` after changing the installer's flags, to set an optional one.

| Variable | What it supplies | Where it comes from |
| --- | --- | --- |
| `BIOT_NODE_REGISTRATION_ID` | Stable registration ID present in the server enrollment file | The `registration_id` of this node's entry in the server's enrollment file |
| `BIOT_SERVER_FINGERPRINT` | Lowercase SHA-256 fingerprint of the trusted server identity | The `fingerprint` `mix biot.certs server` printed in the server section |
| `BIOT_SERVER_HOST` | Host the node dials for control | The server's control host |
| `BIOT_SERVER_PORT` (default `4443`) | Server control port; match `BIOT_CONTROL_PORT` | The server's `BIOT_CONTROL_PORT` |
| `BIOT_NODE_DATA_ROOT` | Absolute canonical root for node state and allocations | The installer's data root |
| `BIOT_NODE_RUNTIME_ROOT` | Absolute canonical root for per-Biot agent sockets, cleared on reboot | The installer's runtime root, `/run/biot-node` by default, created by the unit's `RuntimeDirectory=` |
| `BIOT_NODE_BUILDER_IMAGE` | Pinned builder image digest | The installer reads the digest pinned in `config/config.exs` |
| `BIOT_NODE_BINARY_CACHE_URLS`, `BIOT_NODE_BINARY_CACHE_KEYS` | Whitespace-separated Nix cache endpoints and trusted keys | The release has **no default** and refuses to start without both; the installer reads `config/config.exs` and the documented `https://cache.nixos.org` values |
| `BIOT_NODE_CERTFILE`, `BIOT_NODE_KEYFILE`, `BIOT_NODE_CACERTFILE` | Node certificate, private key, and trusted CA | The node certificate you copied, and that directory's `ca.pem` |
| `BIOT_LOG_LEVEL` (default `info`) | Release log level | Optional; one of `debug`, `info`, `notice`, `warning`, `error`, `critical`, `alert`, or `emergency`. Any other value stops the release, and its message lists the accepted levels |

`BIOT_NODE_FETCH_CA_BUNDLE` is optional; if used, it replaces the fetch phase's trust store, so it
must contain public roots as well as any private authority the Git host needs. The node uses the
default Nixpkgs repository and reference unless you deliberately set
`BIOT_NODE_NIXPKGS_REPOSITORY` and `BIOT_NODE_NIXPKGS_REF`.

### How the service runs

The installer writes a systemd **system** service with `User=biot` and `Delegate=yes`. The
delegation is what lets the service account manage the cgroups its rootless containers need; without
it a system service cannot, and the first build fails. It installs the unit it wrote, reloads
systemd, and starts and enables it.

For a systemd **user** service instead, drop `User=` and `Group=`, install the unit under
`~/.config/systemd/user/`, and use `systemctl --user`. A user service needs lingering so its
manager can start it without an interactive login:

```sh
loginctl enable-linger biot
```

### SELinux, when the host enforces it

The node sets the build worker's SELinux label itself. An operator does nothing: every worker and
the startup sandbox probe run with `--security-opt label=type:container_engine_t`, set in
`Biot.Node.Host.Worker`.

The stock `container-selinux` policy is the reason. It lets a plain container *remount* `/proc` but
not *mount* it, and reserves the mount machinery for the container-engine type:

```
allow container_t proc_t:filesystem remount;

fs_mount_all_fs(container_engine_t)
kernel_mount_proc(container_engine_t)
kernel_mounton_proc(container_engine_t)
```

A Biot build worker is a container engine running inside a container: Nix's sandbox creates its own
nested mount and PID namespace and mounts a fresh `/proc`, which is exactly the operation the plain
label denies, so `container_engine_t` is what the worker is rather than a privilege it is asking
for. The plain label's denial reads:

```
avc: denied { mount } for comm="unshare" name="/" dev="proc"
    scontext=system_u:system_r:container_t:s0:... tcontext=system_u:object_r:proc_t:s0
    tclass=filesystem permissive=0
```

On a host without SELinux there is nothing to do either. Podman ignores the label and the container
is unconfined: `go-selinux`'s `InitLabels` returns empty labels and no error when
`selinux.GetEnabled()` is false, and Podman's container storage is what calls it with the worker's
label, so the label is a no-op there rather than an error.

A custom or hardened policy that does not grant `container_engine_t` what the stock policy does is
the one case that needs an operator. Read the denial and ask the policy, not Biot:

```sh
ausearch -m avc -ts recent | audit2why
```

If the record's source type is `container_engine_t` and the target is `proc_t`, permission `mount`,
the host policy is missing the stock grant. `audit2why` reports a missing type-enforcement rule,
not a boolean to toggle, so the change belongs in the host's policy. From Biot's side the same host
never gets a build: the node's startup sandbox probe returns

```
{:error, {:build_sandboxing_unsupported,
  "error: this system does not support the kernel namespaces that are required for sandboxing; use '--no-sandbox' to disable sandboxing"}}
```

and the node refuses to start, because `Host.Setup` is a startup child and `sandbox-fallback =
false` turns Nix's silent unsandboxed success into a visible failure. A host that cannot sandbox
does not accept work.

`--security-opt label=disable` and `--privileged` also make the mount work, and neither is the
contract. The first runs the worker without SELinux confinement; the second grants it host-wide
privilege. The worker needs the type the policy already reserves for a container engine inside a
container, and nothing more. Do not add either as a default.

**Measured on** Fedora Linux 44 with SELinux enforcing, `container-selinux-2.250.0`,
`selinux-policy-44.8`, and Podman 5.8.4. There the node's startup sandbox probe returns `:ok` with
the label where it previously failed, and the ten host integration tests that gate on that probe —
`HostLinuxIntegrationTest` and `SecretsLinuxIntegrationTest` — are no longer excluded and pass.
Other distributions ship their own `container-selinux` policy; check the host's version for the
`container_engine_t` grants above before treating it as covered.

### The worker boundary

The worker has `SYS_ADMIN` because Nix's sandbox needs to mount a fresh `/proc`. That does not make
the node host root:

- the worker's container UID 0 maps to a subordinate host ID, not to host UID 0;
- the capability set is Podman's default set plus `SYS_ADMIN`, with no `SYS_MODULE`, `SYS_RAWIO`,
  `SYS_PTRACE`, `NET_ADMIN`, or `DAC_READ_SEARCH`;
- mounts remain in the worker's mount namespace, not the host's mount table; and
- non-namespaced sysctls are read-only.

Within that boundary, `SYS_ADMIN` permits the worker to mount and remount filesystems and, together
with the worker's unmasked `/proc`, to create the Nix sandbox. It is the capability for the build
sandbox inside the worker, not a request for host privilege. The worker starts with a read-only
image root, `--network none`, and only the allocation's explicit mounts plus its declared tmpfs
paths.

The node stages build support from its own `priv/build_support`, and a release carries that as real
`nix/` and `agent/` directories, so a packaging path that copies the app's `priv` without following
symbolic links would leave the node unable to stage it.

### Check the node

Checks, and the output that means it worked:

```sh
systemctl is-active biot-node
```

prints `active`. `journalctl -u biot-node -f` follows the log. The release writes to standard output
and error, so the journal is the log; there is no log file.

The node refuses to start if its certificate, key, or CA cannot be read, or if the control link
does not authenticate. The `ERROR! Config provider Config.Reader failed with` block from
[Build the releases](#build-the-releases) names a missing setting; a TLS or fingerprint failure
appears as the connection retrying in the log instead.

The node reports connected and ready on the **server**, not in the node's own log:

- the `nodes` page of the web UI, `/nodes`, shows each node's status, platform, capacity, and
  connection;
- `biot nodes` prints the same as a table with `ID`, `STATUS`, `PLATFORM`, `CAPACITY`, `CONNECTION`,
  and `ORPHANS` columns, where `CONNECTION` reads `ready` (`connecting` while the node is still
  synchronizing, `unavailable` while it is not connected);
- `GET /api/nodes` returns it as JSON;
- on the server host, the readiness check prints `{:ok, #PID<...>}` and only
  `{:error, :temporarily_unavailable}` until then:

  ```sh
  /opt/biot/server/bin/server rpc 'Biot.Protocol.NodeId.parse("<node id>") |> elem(1) |> Biot.Server.NodeConnections.ready() |> IO.inspect()'
  ```

The server log also records the node's reports:

```
[info] node observation received
```

with the node ID and connection ID as metadata on the line.

Then create a small Biot and watch it build. The build observation is on the Biot, not the node:
`biot show <name>` prints the desired state, the reported actual state, and the current operation's
outcome; `biot wait <name>` waits for that operation; `biot logs <name>` prints the container's
runtime output; `biot diagnose <name>` prints the failure diagnostic when the build failed. The web
UI's Biot detail page shows the same. A first successful build is the proof that subordinate
mappings, Podman storage and networking, the worker sandbox, and the SELinux policy all work; a
node that only starts its supervisor has not yet proved the deployment contract.

## When a Biot will not start

A newly created Biot that never reaches running is the failure an operator usually meets first.
Work through this in order; each step says which layer to look at next.

1. **`biot show <name>` is the whole picture on one screen.** Read these lines:

   - `desired: running (revision N)` is what you asked for; `actual:` and `container:` are what the
     node reports. After `actual:` comes the data state, then the observation's freshness in
     parentheses: `actual: present (current)` is the live node's report, and `(stale)` means the
     last report arrived over a connection that is no longer current.
   - `waiting for: fetch credential <source>` means the Biot is **not** failing. It is stopped
     because its repository needs a credential the node does not have. Give it one and wait:

     ```sh
     biot fetch-credential set <name> <source>
     biot wait <name>
     ```

   - `actual: never reported` means the node has never sent an observation for this Biot. The
     problem is the node or the control link, not the Biot's own work; go to step 4.
   - `operation: create failed` (or `start`, `stop`, `update environment`, or `destroy`) means the
     node's last action failed. The `failure:` line under it reads `<stage> / <code>: <message>`;
     the stage says where and the code says why. Go to step 2.
   - `container: exited (status N)` means the container did start and then exited. `biot logs
     <name>` prints the application's own output, so this is usually a bug in the code under
     development rather than in the deployment.

2. **`biot diagnose <name>` prints the node's diagnostic for that failure** — the failing command's
   stderr, or the inspection error, bounded to about 64 KiB. This is where the real error text is.
   The `code` on the failure line says what to expect and what to do:

   | `code` | means | what to do |
   | --- | --- | --- |
   | `invalid_source` | a repository or layer source could not be fetched | fix the fetch credential or the ref, then `biot rebuild <name>` |
   | `resolution_failed` | the selected sources could not be pinned to a manifest | check that the ref exists, then `biot rebuild <name>` |
   | `preparation_failed` | the Nix build failed | the diagnostic is Nix's own error; fix what it names, then `biot rebuild <name>` |
   | `invalid_configuration` | the built environment cannot run as it is configured | fix the environment definition, then `biot rebuild <name>` |
   | `container_failed` | the container exited | the node restarts it automatically until its retry budget is spent; `biot logs <name>` shows why it exited |
   | `resource_unavailable` | the node could not finish the work — Podman, a mount, or a full disk | read the node log in step 3; the node retries this by itself until its retry budget is spent |
   | `lost_data`, `ownership_mismatch` | the node lost the Biot's private data, or a host resource is not this Biot's | a person has to act; nothing retries it |
   | `node_abandoned` | the Biot is assigned to a node the operator abandoned | that node refuses connections and will not run anything again; create the Biot again on a live node |

   Four of these mean the desired revision is wrong: `invalid_source`, `resolution_failed`,
   `preparation_failed`, and `invalid_configuration`. The node will not retry them on its own, so
   nothing changes until you do. `biot rebuild <name>` re-resolves and rebuilds the **same**
   selection, so it picks up whatever the repository and the layer refs point at now: a moved
   branch, a corrected environment definition, or a credential that works. It cannot change the
   repository URL or the layer sources themselves, because no command does; for those, destroy the
   Biot and create it again.

3. **If `biot diagnose` has nothing, read the node's own log.** It reports `That Biot has no
   current failure diagnostic.` when the failure was found by inspection rather than by running a
   command, and while the node is disconnected it cannot fetch a diagnostic at all and says `The
   server could not provide that resource right now.` On the node host:

   ```sh
   journalctl -u biot-node -b
   ```

   holds the node's capture faults, its startup sandbox probe, and each retry with its attempt
   count. A node whose log ends at `build_sandboxing_unsupported` will never build anything; that is
   the sandbox case under [SELinux, when the host enforces it](#selinux-when-the-host-enforces-it).

4. **If the node is not ready, no Biot on it can be.** `biot nodes` prints one row per node, and its
   `CONNECTION` column must read `ready`. Anything else is a control-link problem rather than a Biot
   problem: the node's `BIOT_SERVER_FINGERPRINT` must match the server certificate; the node's own
   certificate, key, and CA must be the ones the enrollment file names for its node ID; and the
   control port must be reachable from the node host. Both `journalctl -u biot-server` and
   `journalctl -u biot-node` record the connection retrying, and neither logs a ready node until it
   works.

The web UI's Biot detail page shows the same failure text, and its node list the same connection
state, for when you are already in a browser.

## What this guide does not cover

Day-two operations are not in this guide yet. They are named here so they are a scope cut you take
on knowingly, not a hole you fall into after you start:

- upgrading the server or the node, and rolling back a failed upgrade;
- how the server's database migrations behave across versions;
- backing up and restoring the server's SQLite database;
- renewing or rotating the control-link certificates, beyond the SSH host-key rotation note; leaves
  last 395 days and the authority 25 years, and renewal keeps the leaf's fingerprint, so the clock
  starts at install;
- storage pressure on `BIOT_NODE_DATA_ROOT` and the rootless container store.

## Rootless deployment checklist

Every line has a command and the output that means it worked. Run the server commands on the server
host and the node commands on the node host, with your ports, account, and paths in place of the
examples.

### Server

- **The release is runnable.** `test -x /opt/biot/server/bin/server && echo ok` prints `ok`.
- **It runs as an unprivileged service account.** `systemctl show biot-server -p User` prints
  `User=biot`, not `User=root`.
- **The service is running.** `systemctl is-active biot-server` prints `active`.
- **The configuration parsed.** `journalctl -u biot-server -b | grep -c 'environment variable'`
  prints `0`.
- **The listeners are up.** `ss -ltn | grep -Ec ':(4000|4443|2222)\b'` prints `3`, one `LISTEN`
  line for each of `PORT`, `BIOT_CONTROL_PORT`, and `BIOT_SSH_PORT`.
- **No listener needed root.** Either all three ports are above 1024, or the unit carries only
  `CAP_NET_BIND_SERVICE`. `systemctl show biot-server -p AmbientCapabilities` prints
  `AmbientCapabilities=CAP_NET_BIND_SERVICE` in that case and an empty value otherwise.
- **The enrollment file parses.** `journalctl -u biot-server -b | grep -c 'node registrations'`
  prints `0`; an invalid file stops boot with a `node registrations` message instead.
- **The edge serves both names.** The two `curl` commands in
  [Choose the listeners and the edge](#choose-the-listeners-and-the-edge) print `200` and `404`; a
  TLS error, `NXDOMAIN`, or `502` points at the certificate, the wildcard DNS record, or the
  upstream.
- **The CLI is authenticated.** `biot list` prints `No Biots.` or a table; it prints `you are not
  logged in; run biot login` when no token is saved.

### Node

- **The release is runnable.** `test -x /opt/biot/node/bin/node && echo ok` prints `ok`.
- **It runs as the service account.** `systemctl show biot-node -p User` prints `User=biot`.
- **The service is running.** `systemctl is-active biot-node` prints `active`.
- **The configuration parsed.** `journalctl -u biot-node -b | grep -c 'environment variable'`
  prints `0`.
- **The subordinate range matches the node's settings.** `awk -F: '$1=="biot"{print $2, $3}'
  /etc/subuid /etc/subgid` prints `524288 65536` twice. The first number must equal the node's
  `BIOT_NODE_UID_RANGE_BASE`, and the second must be at least
  `BIOT_NODE_UID_RANGE_LIMIT - BIOT_NODE_UID_RANGE_BASE`. A base that differs from the host's start
  is the failure this line exists to catch: it does not stop the node from booting, but every
  stream then fails with `agent_unreachable`.
- **Podman is rootless.** `podman info --format '{{.Host.Security.Rootless}}'` prints `true`.
- **The uidmap helpers exist.** `command -v newuidmap newgidmap` prints two paths.
- **The host is on cgroup v2.** `stat -fc %T /sys/fs/cgroup` prints `cgroup2fs`.
- **Linger is set, for a user service only.** `loginctl show-user biot -p Linger` prints
  `Linger=yes`; for a `User=biot` system service this line does not apply.
- **The worker sandbox works.** `journalctl -u biot-node -b | grep -c build_sandboxing_unsupported`
  prints `0` after the node starts.
- **The node is connected and ready.** On the server, `biot nodes` prints a row whose `CONNECTION`
  column reads `ready`, or the readiness check in [Check the node](#check-the-node) prints
  `{:ok, #PID<...>}`.
- **The registration and certificates agree.** The readiness check above only succeeds when the
  node's `peer_identity` matches its certificate and `BIOT_SERVER_FINGERPRINT` matches the server's.
  A mismatch is visible in either log as the connection retrying, never as a ready node.
- **A first Biot builds.** `biot show <name>` reports the operation as `succeeded` and a running
  container; this is the one check that exercises the subordinate mappings, storage, networking,
  sandbox, and policy together.
