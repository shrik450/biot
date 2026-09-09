import Config

config :biot_server,
  ecto_repos: [Biot.Server.Repo],
  default_node_id: nil,
  publication_domain: "env.test",
  ssh_advertised_host: "localhost",
  ssh_port: 22,
  control_port: nil,
  control_tls: nil,
  handshake_timeout_ms: 10_000,
  heartbeat_interval_ms: 30_000,
  heartbeat_timeout_ms: 10_000,
  desired_sweep_interval_ms: 60_000,
  diagnostic_timeout_ms: 10_000,
  diagnostic_max_bytes: 256_000,
  max_frame_bytes: 1_000_000

config :biot_node,
  data_root: nil,
  uid_range_base: nil,
  uid_range_count: nil,
  uid_range_limit: nil,
  git_executable: "git",
  nix_executable: "nix",
  nix_instantiate_executable: "nix-instantiate",
  podman_executable: "podman",
  podman_network_command: "slirp4netns",
  flock_executable: "flock",
  setsid_executable: "setsid",
  nix_build_file: Path.expand("../nix/build.nix", __DIR__),
  nix_pin_file: Path.expand("../nix/pin.nix", __DIR__),
  nixpkgs_repository: "https://github.com/NixOS/nixpkgs",
  nixpkgs_ref: "nixos-unstable",
  host_command_timeout_ms: 600_000,
  host_command_max_output_bytes: 256_000,
  server_host: nil,
  server_port: nil,
  server_fingerprint: nil,
  registration_id: nil,
  tls: nil,
  heartbeat_interval_ms: 30_000,
  heartbeat_timeout_ms: 10_000,
  reconnect_backoff_min_ms: 250,
  reconnect_backoff_max_ms: 30_000,
  max_frame_bytes: 1_000_000,
  max_staged_specs: 1_000,
  retry_budget: 5,
  retry_backoff_min_ms: 2_000,
  retry_backoff_max_ms: 300_000,
  observation_interval_ms: 30_000,
  inspection_retry_ms: 15_000,
  cancel_grace_ms: 10_000,
  controller_start_retry_ms: 5_000,
  diagnostic_max_entries_per_biot: 5,
  diagnostic_max_entry_bytes: 65_536

config :biot_node, Biot.Node.Repo,
  foreign_keys: :on,
  busy_timeout: 5_000,
  journal_mode: :wal,
  pool_size: 5

config :biot_server, Biot.Server.Repo, foreign_keys: :on

config :biot_web, BiotWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: BiotWeb.ErrorHTML, json: BiotWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: BiotWeb.PubSub,
  live_view: [signing_salt: "LuqyvXnD"]

config :esbuild,
  version: "0.25.4",
  biot_web: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../apps/biot_web/assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :tailwind,
  version: "4.3.0",
  biot_web: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("../apps/biot_web", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :request_id,
    :node_id,
    :connection_id,
    :received_at,
    :orphaned_allocations,
    :environment_id
  ]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
