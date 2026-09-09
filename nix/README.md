# Environment bundles

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
  biot.files."example/settings".text = "mode = development\n";
  biot.services.web = {
    command = [ "${pkgs.nodejs}/bin/node" "server.js" ];
    directory = "checkout";
    environment.PORT = "3000";
    restart = "on-failure";
  };
}
```

Packages default to an empty list. Packages join in layer order. The earliest
package wins a name collision on `PATH`.

Environment variables, files, and services default to empty attribute sets.
Environment variable names must be shell variable names. Layers cannot set
`BIOT_CONFIG_ROOT`, `HOME`, or `PATH` in shared or service environments. The
bundle sets `BIOT_CONFIG_ROOT` and `HOME`; the runtime only provides the mounts.
Use `biot.packages` for commands.

File names and service directories must be relative paths. They cannot contain
empty, `.`, or `..` segments. Read a declared file from
`$BIOT_CONFIG_ROOT/files/<path>`.

A service must set a non-empty command. Service names can contain letters,
numbers, periods, underscores, and hyphens. Each service defaults its directory
to its name and its restart rule to `on-failure`. Restart rules are `always`,
`on-failure`, and `never`.

The build writes `bundle.json` at the output root. It has this exact shape:

```json
{
  "format": 1,
  "closure_root": "/nix/store/<hash>-biot-environment-bundle",
  "entrypoint": "/nix/store/<hash>-biot-entrypoint/bin/biot-entrypoint",
  "environment_file": "/nix/store/<hash>-biot-environment",
  "config_root": "/nix/store/<hash>-biot-config"
}
```

The keys must match `Biot.Node.EnvironmentBundle`. `closure_root` is the build
output. Retaining its output link retains the entry point, environment file,
config root, runner, and packages.

The config root contains `supervisord.conf` and the declared files under
`files/`. The entry point loads the environment file and starts `supervisord`.
Every executable resolves inside `/nix/store`. The container needs no base
image.

Launch the bundle on a read-only, empty root filesystem. Mount `/nix/store`
read only. Mount private writable directories at `/biot/checkout`,
`/biot/home`, and `/biot/service-data`. The read-only root makes a missing
private mount fail instead of creating temporary state.

The schema uses `supervisord` because it supports several programs and all
three restart rules without root or an init system. It also adds CPython to
each bundle closure, so it costs more storage than a smaller runner. The bundle
does not create a control socket. Per-service control is out of scope for now.

The `stateful-counter` example uses two layers. Both set `BIOT_EXAMPLE` to the
same value, so the module system merges the definitions. The service stores its
value below the service data mount. It serves the declared file at `/message`.
Add `nix/examples/conflicting-layer` as a third source to see both source
locations in the module system conflict error.
