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

The image labels itself with `org.opencontainers.image.version` and
`org.opencontainers.image.revision`. Both are empty unless the build supplies them,
so pass the version you are tagging and the commit it was built from:

```sh
podman build --format docker \
  --build-arg BIOT_VERSION=0.1.0 \
  --build-arg BIOT_REVISION="$(git rev-parse HEAD)" \
  -t biot-server:0.1.0 -f docker/server/Dockerfile .
```

`podman image inspect biot-server:0.1.0 --format '{{ index .Labels "org.opencontainers.image.revision" }}'`
then names the commit that is running.

Docker builds the Docker image format by default, which is what carries the `HEALTHCHECK`. Podman
defaults to the OCI image format, which has no healthcheck field and silently drops it, so pass
`--format docker` (or set `BUILDAH_FORMAT=docker`).

## Run with compose

`compose.yaml` starts one server with the storage, certificates, and identity it needs, so a person
can bring it up and reach the sign-in page.

This is **not a production deployment**. It publishes loopback ports over plain HTTP behind no
edge, and it is a way to run and see the server, not the deployment described in
[docs/deployment.md](../../docs/deployment.md). TLS, the reverse proxy, the wildcard DNS for
previews, and the node machines are all still the operator's. It runs no node, so signing in and
the server's own API work, while creating a Biot needs a node registered with
`BIOT_NODE_REGISTRATIONS`.

Identity is yours. Biot is not an identity provider, and this stack does not become one: it points
at your OIDC provider through `BIOT_OIDC_ISSUER`, `BIOT_OIDC_CLIENT_ID`, and
`BIOT_OIDC_CLIENT_SECRET`. The release refuses an issuer that is not HTTPS, and the provider must
allow the redirect `https://<PHX_HOST>/login/callback`.

The file itself carries no secret values and no certificate material. The secrets come from
`docker/server/.env` and the key material from `docker/server/etc/`, and both paths are ignored by
git.

### Prepare

Generate the control-link certificates with the project's tool, keeping the authority in a
directory of its own. Only the server's material goes into the mounted directory; the authority's
private key (`ca-key.pem`) never does.

```sh
mise exec -- mix biot.certs authority ~/biot-authority
mise exec -- mix biot.certs server ~/biot-authority
mkdir -p docker/server/etc
cp ~/biot-authority/ca.pem ~/biot-authority/server-cert.pem ~/biot-authority/server-key.pem docker/server/etc/
```

Generate the SSH host key:

```sh
ssh-keygen -q -t ed25519 -N "" -f docker/server/etc/ssh-host-key
rm docker/server/etc/ssh-host-key.pub
```

The container runs as uid 10001, so make the material readable by that uid. Rootless Podman can do
this without root; Docker needs the operator's privilege:

```sh
podman unshare chown -R 10001:10001 docker/server/etc   # or: sudo chown -R 10001:10001 docker/server/etc
```

Copy the environment template and fill it in. `.env` holds `SECRET_KEY_BASE` and the OIDC client
secret, so it is never committed.

```sh
cp docker/server/.env.example docker/server/.env
${EDITOR:-vi} docker/server/.env
```

### Bring it up

Run compose from this directory, which is where it reads `.env` and resolves the build context:

```sh
cd docker/server
docker compose up -d --build
```

With Podman, build the image first so the `HEALTHCHECK` survives, because Podman's default OCI
image format drops it and compose's build does not pass `--format docker`:

```sh
podman build --format docker -t biot-server:local -f docker/server/Dockerfile ../..
docker compose up -d
```

Then open `http://<PHX_HOST>:<BIOT_HTTP_PORT>/`, which with the template's defaults is
`http://localhost:4000/`, and follow the sign-in link. The link sends the browser to your provider
and back to `https://<PHX_HOST>/login/callback`; a completed login also needs an edge terminating
TLS for `PHX_HOST`. Without that edge the landing page and the health check still work, and
`/login` reports that the provider is unavailable.

### What persists

- The SQLite database, in the `biot-data` named volume mounted at `/var/lib/biot`.
- The control-link certificates and the SSH host key, in `docker/server/etc/` mounted read-only at
  `/etc/biot`.

Nothing else persists; the container is disposable. `docker compose down` and `up` keep the
database and the server's control and SSH identities. Back up the volume and `etc/` together: node
pins and SSH known-hosts name the server's fingerprints, so replacing those keys breaks them.

## Environment

Every setting below is required; the release stops at boot naming the first one it does not find.
The compose file supplies the last four paths itself and takes the rest from `.env`.

| Variable | What it supplies |
| --- | --- |
| `PHX_HOST` | The control hostname, a lowercase DNS name. |
| `BIOT_SERVER_PUBLICATION_DOMAIN` | The suffix under which preview hostnames are created. `PHX_HOST` must not be the domain or a name below it. |
| `SECRET_KEY_BASE` | Phoenix's signing and encryption key. Generate with `mise exec -- mix phx.gen.secret`. |
| `BIOT_OIDC_ISSUER` | The OIDC provider's HTTPS issuer URL. |
| `BIOT_OIDC_CLIENT_ID` | The server's OIDC client id. |
| `BIOT_OIDC_CLIENT_SECRET` | The server's OIDC client secret. |
| `BIOT_SERVER_DATABASE` | Absolute path to the SQLite database. |
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

## Ports

`PORT`, `BIOT_CONTROL_PORT`, and `BIOT_SSH_PORT` are all above 1024, so the container needs no
capability. Compose publishes them on loopback: change a bind address in `compose.yaml` when a node
or an SSH client on another host must reach that listener. Put a reverse proxy in front of `PORT`
for TLS and the preview wildcard; the container does not terminate TLS itself.

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
