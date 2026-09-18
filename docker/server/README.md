# Server image

Builds the `server` mix release into a small runtime image. The image carries the release and
nothing else: every setting and every secret arrives through the environment at run time, and the
container runs as the unprivileged `biot` user, uid and gid 10001.

Build from the repository root. The build stage compiles the umbrella and installs esbuild; the
release's own `mix release` steps build and digest the web assets, so there is no separate asset
step.

```sh
podman build --format docker -t biot-server -f docker/server/Dockerfile .
```

Docker builds the Docker image format by default, which is what carries the `HEALTHCHECK`. Podman
defaults to the OCI image format, which has no healthcheck field and silently drops it, so pass
`--format docker` (or set `BUILDAH_FORMAT=docker`).

## Run

Every setting below is required; the release stops at boot naming the first one it does not find.
Generate `SECRET_KEY_BASE` with `mise exec -- mix phx.gen.secret`, and the certificates and SSH
host key with the procedures in [docs/deployment.md](../../docs/deployment.md).

| Variable | What it supplies |
| --- | --- |
| `PHX_HOST` | The control hostname, a lowercase DNS name. |
| `BIOT_SERVER_PUBLICATION_DOMAIN` | The suffix under which preview hostnames are created. `PHX_HOST` must not be the domain or a name below it. |
| `SECRET_KEY_BASE` | Phoenix's signing and encryption key. |
| `BIOT_OIDC_ISSUER` | The OIDC provider's HTTPS issuer URL. |
| `BIOT_OIDC_CLIENT_ID` | The server's OIDC client id. |
| `BIOT_OIDC_CLIENT_SECRET` | The server's OIDC client secret. |
| `BIOT_SERVER_DATABASE` | Absolute path to the SQLite database. Put it on a writable volume. |
| `BIOT_SSH_ADVERTISED_HOST` | The hostname or address printed for SSH clients. |
| `BIOT_SSH_PORT` | The SSH listener port. |
| `BIOT_SSH_HOST_KEY_FILE` | Absolute path to the SSH host key file. |
| `BIOT_CONTROL_CERTFILE` | The server's node-control TLS certificate. |
| `BIOT_CONTROL_KEYFILE` | The server's node-control TLS private key. |
| `BIOT_CONTROL_CACERTFILE` | The CA that signs the nodes' control certificates. |

Settings an operator normally also sets, each with a default:

| Variable | Default | What it supplies |
| --- | --- | --- |
| `PORT` | `4000` | The HTTP listener for the web UI, the API, and the preview edge. |
| `BIOT_CONTROL_PORT` | `4443` | The mutually authenticated node-control listener. |
| `BIOT_NODE_REGISTRATIONS` | unset | The operator's node enrollment file. Without it the server accepts no node. |
| `BIOT_LOG_LEVEL` | `info` | Release log level. |
| `BIOT_SESSION_LIFETIME_HOURS` | `168` | How long a browser session stays valid. |
| `BIOT_CREDENTIAL_MAX_LIFETIME_DAYS` | `90` | The longest lifetime a person may give a bearer token. |
| `BIOT_AUTH_CHECK_INTERVAL_MS` | `60000` | How often every live proof is rechecked. |

The remaining `BIOT_*` settings are protocol timeouts and bounds with defaults; they do not need to
be set to boot. `config/releases/server.exs` is the complete list.

## Ports and paths

The image creates `/var/lib/biot` owned by `biot` as the natural place for the database, and
`/etc/biot` for mounted certificate material. The operator chooses both paths and passes them in
`BIOT_SERVER_DATABASE`, `BIOT_SSH_HOST_KEY_FILE`, and the `BIOT_CONTROL_*` settings.

Mount the database directory on a volume, owned by uid 10001, or the container loses its data when
it is replaced:

```sh
podman run -d --name biot-server \
  -p 4000:4000 -p 4443:4443 -p 2222:2222 \
  -v biot-data:/var/lib/biot \
  -v /etc/biot:/etc/biot:ro \
  -e PHX_HOST=biot.example.com \
  -e BIOT_SERVER_PUBLICATION_DOMAIN=preview.example.com \
  -e SECRET_KEY_BASE="$(mise exec -- mix phx.gen.secret)" \
  -e BIOT_OIDC_ISSUER=https://id.example.com \
  -e BIOT_OIDC_CLIENT_ID=biot \
  -e BIOT_OIDC_CLIENT_SECRET=... \
  -e BIOT_SERVER_DATABASE=/var/lib/biot/server.sqlite3 \
  -e BIOT_SSH_ADVERTISED_HOST=biot.example.com \
  -e BIOT_SSH_PORT=2222 \
  -e BIOT_SSH_HOST_KEY_FILE=/etc/biot/ssh-host-key \
  -e BIOT_CONTROL_CERTFILE=/etc/biot/server-cert.pem \
  -e BIOT_CONTROL_KEYFILE=/etc/biot/server-key.pem \
  -e BIOT_CONTROL_CACERTFILE=/etc/biot/ca.pem \
  biot-server
```

`PORT`, `BIOT_CONTROL_PORT`, and `BIOT_SSH_PORT` are all above 1024, so the container needs no
capability. Put a reverse proxy in front of `PORT` for TLS and the preview wildcard, as
[docs/deployment.md](../../docs/deployment.md) describes; the container does not terminate TLS
itself.

## Health

The image carries a `HEALTHCHECK` that runs `curl` against `http://127.0.0.1:$PORT/health` every 30
seconds, starting 30 seconds after the container starts. The endpoint is unauthenticated, creates
no session, and answers `200 {"status":"ok"}` when the server can run a query against its database
and `503 {"status":"unavailable"}` when it cannot. It is deliberately not a check of node
connectivity: a server with no node connected is still a working server.

The endpoint is reachable on loopback and on any host outside the preview domain, and
`/health` is excluded from the application's HTTPS redirect so an orchestrator that does not go
through the edge still reaches it. A Kubernetes `httpGet` probe to the pod's own address works
without extra headers; a preview hostname is never answered by it, so a published service keeps its
own `/health`.
