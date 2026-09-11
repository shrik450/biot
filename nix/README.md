# Environment bundles

## Pin a source

`pin.nix` asks Nix to resolve one Git reference and compute its NAR hash. Pass the URL and
reference as arguments so author input never becomes Nix source:

```sh
nix-instantiate \
  --eval \
  --strict \
  --json \
  nix/pin.nix \
  --argstr url <repository URL> \
  --argstr ref <Git reference>
```

The result contains `revision` and `nar_hash`.

## Build a bundle

`build.nix` reads one encoded `Biot.Protocol.Manifest` and builds a launch
bundle for one platform. Pass only the manifest JSON path and the system:

```sh
nix build \
  --extra-experimental-features 'nix-command' \
  --file nix/build.nix \
  --argstr manifest <node private path>/manifest.json \
  --argstr system x86_64-linux \
  --out-link <node private path>/<environment id>
```

The output link is the garbage collection root for that environment artifact.
Its node-private name keeps each artifact until the node removes that artifact.

The manifest JSON must have the exact shape from
`Biot.Protocol.Manifest.encode/1`. Nix maps its fields as follows:

| Manifest field | Build use |
| --- | --- |
| `base_nixpkgs` | Nix fetches the pinned revision and NAR hash. The `nixpkgs` source name maps to `https://github.com/NixOS/nixpkgs`. |
| `layers` | Nix fetches each pinned Git source and evaluates its root `default.nix` in list order. |
| `project_snapshot` | Nix does not use it. The checkout is a private writable mount at runtime. |
| `digest` | The node uses it to identify the manifest. It does not change the Nix evaluation. |

Each pinned source uses the canonical `<source>#<revision>#<NAR hash>` string
from `PinnedSource.to_string/1`. Nix 2.35 verifies the NAR hash through
`builtins.fetchGit`. The build needs `nix-command`, but it does not need the
`flakes` feature.

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
