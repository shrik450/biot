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

## Build the releases

Build both releases from a checkout on the machine that runs them, or on a machine with the same
architecture. This needs the pinned Elixir, OTP, and the project's dependencies; it does not need
root.

The repository pins its toolchain in `.mise.toml`: **Erlang 28.5** and **Elixir 1.20.4 with OTP
28**. Install [mise](https://mise.jdx.dev), then run `mise install` in the checkout to fetch both;
the commands below go through `mise exec --`, which puts those versions on `PATH`:

```sh
mise install
mise exec -- mix deps.get
MIX_ENV=prod mise exec -- mix release server
MIX_ENV=prod mise exec -- mix release node
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

## Server

The server's runtime needs no root; only the one-time setup steps marked **Root.** do. It needs an
unprivileged service account, ordinary ownership of its database and key material, and listeners on
ports the service account can bind.

### 1. Create the service account and deploy the release

Each step that needs root is marked **Root.**; the rest run as yourself.

1. **Root.** Create the service account:

   ```sh
   sudo useradd --system --create-home --shell /usr/sbin/nologin biot
   ```

2. **Root.** Create the directories the server owns and the location the release will live in:

   ```sh
   sudo install -d -o biot -g biot -m 0750 /opt/biot/server /var/lib/biot /etc/biot
   ```

   The SQLite database lives under `/var/lib/biot`; the TLS material, SSH host key, and the
   enrollment file live under `/etc/biot`.

3. **Root.** Copy the built release into its location and give it to the account:

   ```sh
   sudo cp -r _build/prod/rel/server/. /opt/biot/server/
   sudo chown -R biot:biot /opt/biot/server
   ```

4. Produce the control-link certificates. The authority is created once and never replaced:

   ```sh
   mise exec -- mix biot.certs authority /etc/biot/certs
   mise exec -- mix biot.certs server /etc/biot/certs
   ```

   **Root** to write under `/etc/biot/certs` (the command creates the directory), or run this in a
   directory you own and copy `ca.pem` and `server-cert.pem` into `/etc/biot/certs` afterwards.
   `ca-key.pem` stays with the operator and never goes to a node. The second command prints:

   ```json
   {
     "key": "/etc/biot/certs/server-key.pem",
     "cert": "/etc/biot/certs/server-cert.pem",
     "fingerprint": "<64 lowercase hex>"
   }
   ```

   That `fingerprint` is the server's identity. A node pins it as `BIOT_SERVER_FINGERPRINT`, and the
   `cert` and `key` are the server's `BIOT_CONTROL_CERTFILE` and `BIOT_CONTROL_KEYFILE`.

   A leaf certificate is valid for **395 days (about 13 months)** from the day you issue it; the
   authority is valid for 25 years. Renewing a leaf reuses its key, so its fingerprint does not
   change and every registration and pin that names it stays valid. The clock starts when you run
   the command above, not when Biot starts.

5. Generate the SSH host key with any OpenSSH mechanism, for example:

   ```sh
   sudo ssh-keygen -q -t ed25519 -N "" -f /etc/biot/ssh-host-key
   sudo chown biot:biot /etc/biot/ssh-host-key /etc/biot/ssh-host-key.pub
   ```

   The file is `BIOT_SSH_HOST_KEY_FILE`. The SSH host-key rotation note below covers replacing it.

   Check the file now, and again once the server is running:

   ```sh
   sudo ssh-keygen -lf /etc/biot/ssh-host-key
   ```

   prints `256 SHA256:<fingerprint> <comment> (ED25519)`. The `SHA256:` value is the key's identity;
   the account page (see **Sign in and create a bearer token**) lists it under `ssh host keys`, and
   `GET /api/deployment` returns it as `ssh.host_keys[].fingerprint`. The two must be the same
   value. If the account page shows a different fingerprint, the running daemon is serving a key
   other than the file you just checked, which means the file changed after the daemon started or
   the service reads a different path.

6. Create the operator's node enrollment file (section 3, `BIOT_NODE_REGISTRATIONS`). **Root** to
   write it under `/etc/biot`; keep it readable by the service account and the operator, not by
   anyone else.

### 2. Choose the listeners and the edge

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

This check needs the server running (section 4). It proves the certificate, the DNS, and the
forwarding all work:

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
unprivileged listeners, or grant only `CAP_NET_BIND_SERVICE` to the server service. That capability
allows low-port binding; it is not a reason to run the server as root.

### 3. Set the server release environment

The release validates these values before it serves requests. `PHX_HOST` and
`BIOT_SERVER_PUBLICATION_DOMAIN` must be lowercase DNS names, and the control host must not be the
publication domain or a name below it.

| Variable | What it supplies | Where it comes from |
| --- | --- | --- |
| `PHX_HOST` | Control hostname used by the browser login flow | Chosen by the operator; a DNS name you point at the edge |
| `BIOT_SERVER_PUBLICATION_DOMAIN` | Suffix under which published preview hostnames are created | Chosen by the operator; `PHX_HOST` must not be under it |
| `SECRET_KEY_BASE` | Phoenix signing and encryption key | `mise exec -- mix phx.gen.secret` |
| `BIOT_OIDC_ISSUER` | The OIDC provider's HTTPS issuer URL | The provider's app registration |
| `BIOT_OIDC_CLIENT_ID`, `BIOT_OIDC_CLIENT_SECRET` | The server's OIDC client credentials | The provider's app registration |
| `BIOT_SERVER_DATABASE` | Absolute path to the SQLite database | Chosen by the operator, for example `/var/lib/biot/server.sqlite3` |
| `BIOT_SSH_ADVERTISED_HOST` | Hostname or address printed for SSH clients | Chosen by the operator |
| `BIOT_SSH_PORT` | SSH listener port | Chosen by the operator |
| `BIOT_SSH_HOST_KEY_FILE` | SSH host-key file | Generated in section 1, step 5 |
| `BIOT_CONTROL_CERTFILE`, `BIOT_CONTROL_KEYFILE`, `BIOT_CONTROL_CACERTFILE` | Server certificate, private key, and CA for node control TLS | `mix biot.certs server` prints `cert` and `key`; the CA is that directory's `ca.pem` |
| `BIOT_NODE_REGISTRATIONS` | Operator enrollment file for the nodes this server accepts | Written by the operator; see below |
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
`abandoned`. The server imports the file at boot; to reimport it on a running server without a
restart:

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
second path setting. Confirm the result before restarting, with the same check as step 5:

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

### 4. Install, start, and check the server service

Save this as `biot-server.service`. **I did not install it on any host**; the paths below are the
ones from sections 1 and 3, and each line an operator must adjust is called out after it.

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

Lines to adjust:

- `User=` and `Group=`: the account from section 1.
- `WorkingDirectory=`, `ExecStart=`, `ExecStop=`: where you copied the release in section 1.
- `EnvironmentFile=`: the file holding the variables from section 3. Create it mode 0600 and owned
  by `biot`, because it holds `SECRET_KEY_BASE` and the OIDC client secret.
- Add `AmbientCapabilities=CAP_NET_BIND_SERVICE` and `CapabilityBoundingSet=CAP_NET_BIND_SERVICE`
  only when one of the listeners is below 1024.

`bin/server start` runs in the foreground, which is what `Type=simple` expects. `ExecStop` works
because a release names a local Erlang node by default, which is what `bin/server stop` talks to.

**Root** installs and starts the unit:

```sh
sudo install -o root -g root -m 0644 biot-server.service /etc/systemd/system/biot-server.service
sudo systemctl daemon-reload
sudo systemctl enable --now biot-server
```

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

Then check the service from outside: the HTTP endpoint answers through the reverse proxy and the
OIDC redirect returns to `https://<PHX_HOST>/login/callback`; the control port is reachable from
each node host; the SSH advertised host and port are reachable by an SSH client.

Start each node only after its entry is in the enrollment file and its certificate is in place. The
server imports the file at boot, or with the `reload` command in section 3; an unregistered node
cannot become ready.

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

The node has a one-time host setup, normally performed with root-equivalent package and account
administration. After that setup, start the node release as the dedicated service user. Every build
worker is a rootless Podman container with its own subordinate UID/GID range.

### 1. Create the service account and persistent paths

Each step that needs root is marked **Root.**; the rest run as yourself. If the server and node
share a host, this is the same account from the server section.

1. **Root.** Create the service account:

   ```sh
   sudo useradd --system --create-home --shell /usr/sbin/nologin biot
   ```

2. **Root.** Create the node's data root and the location for its release and certificate material:

   ```sh
   sudo install -d -o biot -g biot -m 0750 /opt/biot/node /var/lib/biot/node /etc/biot/certs
   ```

   `BIOT_NODE_DATA_ROOT` is `/var/lib/biot/node`; the node certificate, key, and CA go under
   `/etc/biot/certs`.

3. **Root.** Copy the built node release and give it to the account:

   ```sh
   sudo cp -r _build/prod/rel/node/. /opt/biot/node/
   sudo chown -R biot:biot /opt/biot/node
   ```

4. Issue this node's certificate from the same authority the server uses:

   ```sh
   mise exec -- mix biot.certs node /etc/biot/certs biot-node-1
   ```

   **Root** to write under `/etc/biot/certs`, or run it in a directory you own and copy the files.
   The name is a lowercase DNS label and only names the files,
   `/etc/biot/certs/node-biot-node-1-cert.pem` and `...-key.pem`. The command prints the same JSON
   shape as the server's; its `fingerprint` is the `peer_identity` the server's enrollment file
   must carry for this node. Each node name is distinct, and `ca.pem` is its
   `BIOT_NODE_CACERTFILE`.

5. Obtain the builder image the release pins, as the service account, so it lands in that account's
   rootless store:

   ```sh
   sudo -u biot podman pull docker.io/nixos/nix@sha256:29fc5fe207f159ceb0143c25c19c774062fee02ce5eda118f3067547b3054894
   ```

   **Root** for `sudo -u`, or log in as the account and run `podman pull`. The digest is the
   release's pinned builder image in `config/config.exs`; section 5 sets `BIOT_NODE_BUILDER_IMAGE`
   to it.

### 2. Give the service account a large enough subordinate range

The node gives each Biot a slice of the service account's subordinate UID/GID range and passes that
slice to Podman. **The node's range is the host's range**: the numbers the node is configured with
are host subordinate IDs, so the node's base has to be the start the host assigned. Add matching
subordinate UID and GID entries for the service account in `/etc/subuid` and `/etc/subgid` (or with
the host's equivalent account-management tools).

**Root.** Add the entries with the host's account tooling. For example, this gives `biot` 65536
subordinate IDs starting at 524288:

```sh
usermod --add-subuids 524288-589823 \
  --add-subgids 524288-589823 biot
```

Read back what the host assigned, because the node must be configured with the same start:

```sh
awk -F: '$1=="biot"{print $2, $3}' /etc/subuid /etc/subgid
```

Each line prints `<start> <count>`. The two rules are:

```text
BIOT_NODE_UID_RANGE_BASE == the host's subuid start
subordinate count        >= BIOT_NODE_UID_RANGE_LIMIT - BIOT_NODE_UID_RANGE_BASE
```

`BIOT_NODE_UID_RANGE_BASE` is **not** a free logical origin: it must equal the first subordinate ID
the host assigned to the service account. The node maps each Biot's slice onto the host range
through that base, and it checks the agent connection's peer UID against the same numbers, so a
mismatched base fails every ownership check and every stream with `agent_unreachable` — at stream
time, not at boot. The release default is `100000`, which matches the project's container image; a
host that assigns a different start (Fedora starts at `524288`) must set the base to it.

| Setting | Meaning |
| --- | --- |
| `BIOT_NODE_UID_RANGE_BASE` (default `100000`) | The host's subordinate start; must match `/etc/subuid` |
| `BIOT_NODE_UID_RANGE_COUNT` (default `1024`) | IDs reserved by each Biot |
| `BIOT_NODE_UID_RANGE_LIMIT` (default `BASE + 65536`) | Exclusive end of the node's span; must not exceed `BASE + <host count>` |

If `LIMIT - BASE` is larger than the host's subordinate count, allocation or worker startup fails
with an insufficient-UID error; increase the host range or reduce the node's span.

### 3. Install the rootless container prerequisites

**Root.** Install these with the host package manager for the node service account and host kernel:

| Requirement | Why it is needed |
| --- | --- |
| Podman | Starts the allocation and runtime containers without a daemon or root |
| `newuidmap` and `newgidmap` (normally the `uidmap` package) | Applies the subordinate UID/GID maps |
| `fuse-overlayfs` or an in-kernel overlay driver | Gives rootless Podman a writable container storage driver |
| `slirp4netns` or `pasta` | Provides rootless container networking where needed |
| Enabled user namespaces | Lets Podman create the rootless and per-Biot mappings |
| cgroup v2 with usable delegation | Lets the service account manage its containers; use Podman's `cgroupfs` manager if systemd delegation is unsuitable |

### 4. Choose how the node service starts

1. **Root.** For a systemd **user** service, enable lingering for the service account so its user
   manager can start the node without an interactive login:

   ```sh
   loginctl enable-linger biot
   ```

2. For a system service with `User=biot`, lingering is not required. The service still needs a
   usable cgroup v2 delegation; configure Podman with `--cgroup-manager=cgroupfs` when the system
   service cannot receive the delegation it needs.

### 5. Configure the node release

The node must have a matching registration and mutually authenticated control credentials. These
values are read by `config/releases/node.exs`; every one is required except `BIOT_LOG_LEVEL`,
which is optional:

| Variable | What it supplies | Where it comes from |
| --- | --- | --- |
| `BIOT_NODE_REGISTRATION_ID` | Stable registration ID present in the server enrollment file | Chosen by the operator; the `registration_id` of this node's entry in the server's enrollment file |
| `BIOT_SERVER_FINGERPRINT` | Lowercase SHA-256 fingerprint of the trusted server identity | The `fingerprint` `mix biot.certs server` printed in the server section |
| `BIOT_SERVER_HOST` | Host the node dials for control | The server's control host |
| `BIOT_SERVER_PORT` (default `4443`) | Server control port; match `BIOT_CONTROL_PORT` | The server's `BIOT_CONTROL_PORT` |
| `BIOT_NODE_DATA_ROOT` | Absolute canonical root for node state and allocations | Chosen by the operator; created in step 1 |
| `BIOT_NODE_BUILDER_IMAGE` | Pinned builder image digest | Required; set it to the digest pinned in `config/config.exs` |
| `BIOT_NODE_BINARY_CACHE_URLS`, `BIOT_NODE_BINARY_CACHE_KEYS` | Whitespace-separated Nix cache endpoints and trusted keys | Required; the release has **no default** and refuses to start without both. Use `https://cache.nixos.org` and `cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=`, or the substituters you trust |
| `BIOT_NODE_CERTFILE`, `BIOT_NODE_KEYFILE`, `BIOT_NODE_CACERTFILE` | Node certificate, private key, and trusted CA | The `cert` and `key` from step 4, and that directory's `ca.pem` |
| `BIOT_LOG_LEVEL` (default `info`) | Release log level | Optional; one of `debug`, `info`, `notice`, `warning`, `error`, `critical`, `alert`, or `emergency`. Any other value stops the release, and its message lists the accepted levels |

These values go in the service's `EnvironmentFile`, named in section 8. Set the UID range values
from step 2 in the same file. `BIOT_NODE_FETCH_CA_BUNDLE` is optional; if used, it replaces the
fetch phase's trust store, so it must contain public roots as well as any private authority the Git
host needs. The node uses the default Nixpkgs repository and reference unless you deliberately set
`BIOT_NODE_NIXPKGS_REPOSITORY` and `BIOT_NODE_NIXPKGS_REF`.

### 6. SELinux, when the host enforces it

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

### 7. Understand the worker boundary

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

### 8. Install, start, and check the node service

Save this as `biot-node.service`. **I did not install it on any host**; the paths below are the
ones from sections 1 and 5, and each line an operator must adjust is called out after it.

```ini
[Unit]
Description=Biot node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=biot
Group=biot
WorkingDirectory=/opt/biot/node
EnvironmentFile=/etc/biot/node.env
ExecStart=/opt/biot/node/bin/node start
ExecStop=/opt/biot/node/bin/node stop
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Lines to adjust:

- `User=` and `Group=`: the account from section 1.
- `WorkingDirectory=`, `ExecStart=`, `ExecStop=`: where you copied the release in section 1.
- `EnvironmentFile=`: the file holding the variables from section 5. Create it mode 0600 and owned
  by `biot`, because it holds the node private key path and the control secrets.

For a systemd **user** service instead, drop `User=` and `Group=`, install the unit under
`~/.config/systemd/user/`, use `systemctl --user`, and enable lingering (section 4). Rootless
Podman needs a cgroup it can manage; see the cgroup note in section 4 either way.

**Root** installs and starts the unit:

```sh
sudo install -o root -g root -m 0644 biot-node.service /etc/systemd/system/biot-node.service
sudo systemctl daemon-reload
sudo systemctl enable --now biot-node
```

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
   the sandbox case in section 6.

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
- **The edge serves both names.** The two `curl` commands in section 2 print `200` and `404`; a TLS
  error, `NXDOMAIN`, or `502` points at the certificate, the wildcard DNS record, or the upstream.
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
  column reads `ready`, or the readiness check in section 8 prints `{:ok, #PID<...>}`.
- **The registration and certificates agree.** The readiness check above only succeeds when the
  node's `peer_identity` matches its certificate and `BIOT_SERVER_FINGERPRINT` matches the server's.
  A mismatch is visible in either log as the connection retrying, never as a ready node.
- **A first Biot builds.** `biot show <name>` reports the operation as `succeeded` and a running
  container; this is the one check that exercises the subordinate mappings, storage, networking,
  sandbox, and policy together.
