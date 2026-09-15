# Environment bundles

Environment resolution has two phases, both run by the node in a private build worker. They are
not operator commands.

## Fetch and pin inputs

`fetch.nix` is the trusted, networked phase. It receives an encoded
`Biot.Protocol.EnvironmentSelection`, resolves moving Git refs, fetches the base package set and
layers, and stages the release's own build support. The node invokes it with an expression so
selection values remain data rather than Nix source:

```sh
nix build \
  --impure \
  --expr 'import /biot/build-support/nix/fetch.nix' \
  --argstr selection '<encoded selection>' \
  --arg buildSupport /biot/build-support \
  --argstr system x86_64-linux \
  --out-link /biot/environments/<environment id>/staged \
  --store /biot/store
```

The fetch output contains `pins.json` plus symlinks to every input. `pins.json` records each store
path and NAR hash, and records a revision for each source. The symlinks make the one `staged`
out-link the garbage-collection root for the complete input set. `Biot.Node.Host.StagedInputs`
strictly parses this file and combines its pins with the original selection to produce the
`Biot.Protocol.Manifest` reported to the server.

## Build a bundle

`build.nix` is the pure, offline user-evaluation phase. The node mounts only the store objects
named by the parsed staging record and passes their mounted paths and NAR hashes as `staged`:

```sh
nix build \
  --option pure-eval true \
  --expr 'import /biot/staged/build-support/<store object>/nix/build.nix' \
  --argstr staged '<encoded staged inputs>' \
  --argstr system x86_64-linux \
  --out-link /biot/environments/<environment id>/root \
  --store /biot/store
```

`builtins.fetchTree` checks each mounted object's NAR hash. No source URL or credential reaches
this phase, and no source can enter through another path. The output link retains the launch
bundle and its complete closure until the node releases that environment.

Each layer is a Nix module with these options:

```nix
{ pkgs, ... }:

{
  biot.packages = [ pkgs.git ];
  biot.environment.EDITOR = "vim";
  biot.shell = pkgs.zsh;
  biot.files."example/settings".text = "mode = development\n";
  biot.services.web = {
    command = [ "${pkgs.nodejs}/bin/node" "server.js" ];
    directory = { root = "checkout"; path = "."; };
    environment.PORT = "3000";
    restart = "on-failure";
  };
}
```

Packages default to an empty list. Packages join in layer order. The earliest
package wins a name collision on `PATH`.

Environment variables, files, and services default to empty attribute sets.
Environment variable names must be shell variable names. Layers cannot set
`BIOT_CONFIG_ROOT`, `HOME`, `PATH`, or `TERM` in shared or service
environments. The bundle sets the first three values. The agent sets `TERM` for
each shell. Use `biot.packages` for commands.

File names must be relative paths with no empty, `.` or `..` segments. A
service directory path is either `.` or a relative path with no empty, `.` or
`..` segments. Read a declared file from
`$BIOT_CONFIG_ROOT/files/<path>`.

A service must set a non-empty command. Service names can contain letters,
numbers, periods, underscores, and hyphens. The name `biot-agent` is reserved.
Each service directory defaults to `{ root = "checkout"; path = "."; }`.
The root can be `checkout` or `service_data`. Each restart rule defaults to
`on-failure`. Restart rules are `always`, `on-failure`, and `never`.

`biot.shell` defaults to bash. Set it to another package, such as `pkgs.zsh`,
to change the shell that starts when an agent request has no command.

The build writes `bundle.json` at the output root. It has this exact shape:

```json
{
  "format": 1,
  "closure_root": "/nix/store/<hash>-biot-environment-bundle",
  "rootfs": "/nix/store/<hash>-biot-rootfs",
  "entrypoint": "/nix/store/<hash>-biot-entrypoint/bin/biot-entrypoint",
  "shell_entrypoint": "/nix/store/<hash>-biot-shell-entrypoint/bin/biot-shell-entrypoint",
  "environment_file": "/nix/store/<hash>-biot-environment",
  "config_root": "/nix/store/<hash>-biot-config"
}
```

The keys must match `Biot.Node.EnvironmentBundle`. `closure_root` is the build
output. Retaining its output link retains the root filesystem, both entry
points, the agent, the runner, and all packages.

The config root contains declared files under `files/`. The entry point starts
`supervisord` with the generated runner configuration. Every executable
resolves inside `/nix/store`.

Launch the bundle with its `rootfs`. Mount `/nix/store` read only. Mount private
writable directories at `/biot/checkout`, `/biot/home`,
`/biot/service-data`, and `/biot/run`. Mount `/biot/secrets` read only. The
root filesystem contains the system files and mount points that Podman needs.

The runner includes the Go `biot-agent`. The agent listens on
`/biot/run/agent.sock`. The repository checks in the agent's vendor tree, so
Nix builds its pinned module graph without network module downloads.

Generated wrappers own service restart rules. Supervisord cannot limit restarts
after a process first reaches its running state. Each wrapper applies bounded
backoff and stops after five starts. It writes one exhaustion line to the
runtime log. Supervisord stays alive when one wrapper stops.

Each service and shell starts with a clean environment. Its entry loads the
bundle environment and current files from `/biot/secrets`. The runner and agent
do not load secret values.

The `stateful-counter` example uses two layers. Both set `BIOT_EXAMPLE` to the
same value, so the module system merges the definitions. The service stores its
value below the service data mount. Its layer selects zsh for shells. The
service serves the declared file at `/message`.
Add `nix/examples/conflicting-layer` as a third source to see both source
locations in the module system conflict error.

## Trusting a private Git host

`BIOT_NODE_FETCH_CA_BUNDLE` is an optional absolute path to the certificate authorities the
node's trusted fetch phase trusts. Set it when a repository or layer lives on a Git host the
builder image's own roots do not cover. It **replaces** that trust store rather than adding to it,
the way `SSL_CERT_FILE` does not add to it for any other tool, so a file holding only a private
authority makes public fetches fail, including the base package set. Build a complete bundle by
putting the image's own roots first:

```sh
podman run --rm --network none "$BIOT_NODE_BUILDER_IMAGE" \
  cat /nix/var/nix/profiles/default/etc/ssl/certs/ca-bundle.crt > roots.pem
cat roots.pem private-authority.pem > /etc/biot/fetch-ca-bundle.pem
```

Leave it unset unless a fetch needs it. Only the fetch phase reads it: no user build and no
runtime trusts an operator's authority, and the node's own checkout clone trusts whatever the node
host trusts, so an authority needed for a private checkout belongs in the host's own store as well.
