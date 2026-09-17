import Config

config :biot_server,
  ecto_repos: [Biot.Server.Repo],
  default_node_id: nil,
  control_host: "localhost",
  publication_domain: "env.test",
  ssh_advertised_host: "localhost",
  ssh_port: 22,
  control_port: nil,
  control_tls: nil,
  oidc: nil,
  control_session_lifetime_ms: 7 * 24 * 60 * 60 * 1000,
  credential_max_lifetime_ms: 90 * 24 * 60 * 60 * 1000,
  ssh_host_key_file: nil,
  credential_last_used_interval_ms: 60 * 60 * 1000,
  preview_handoff_ttl_ms: 60 * 1000,
  handshake_timeout_ms: 10_000,
  heartbeat_interval_ms: 30_000,
  heartbeat_timeout_ms: 10_000,
  desired_sweep_interval_ms: 60_000,
  expiry_sweep_interval_ms: 60_000,
  auth_check_interval_ms: 60_000,
  node_request_timeout_ms: 10_000,
  node_response_max_bytes: 256_000,
  stream_open_timeout_ms: 30_000,
  max_frame_bytes: 1_000_000,
  preview_request_max_bytes: 8_000_000,
  preview_request_chunk_bytes: 65_536,
  preview_head_max_bytes: 65_536,
  preview_exchange_timeout_ms: 30_000,
  preview_handshake_timeout_ms: 10_000

config :biot_node,
  data_root: nil,
  uid_range_base: nil,
  uid_range_count: nil,
  uid_range_limit: nil,
  git_executable: "git",
  podman_executable: "podman",
  podman_network_command: "slirp4netns",
  flock_executable: "flock",
  setsid_executable: "setsid",
  mkfifo_executable: "mkfifo",
  head_executable: "head",
  cat_executable: "cat",
  sleep_executable: "sleep",
  builder_image:
    "docker.io/nixos/nix@sha256:29fc5fe207f159ceb0143c25c19c774062fee02ce5eda118f3067547b3054894",
  binary_cache_urls: ["https://cache.nixos.org"],
  binary_cache_keys: ["cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="],
  nixpkgs_repository: "https://github.com/NixOS/nixpkgs",
  nixpkgs_ref: "nixos-unstable",
  host_command_timeout_ms: 600_000,
  worker_timeout_ms: 3_600_000,
  host_command_max_output_bytes: 256_000,
  host_command_max_stderr_bytes: 256_000,
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
  max_streams: 128,
  max_streams_per_biot: 16,
  retry_budget: 5,
  retry_backoff_min_ms: 2_000,
  retry_backoff_max_ms: 300_000,
  observation_interval_ms: 30_000,
  inspection_retry_ms: 15_000,
  cancel_grace_ms: 10_000,
  controller_start_retry_ms: 5_000,
  container_events_retry_ms: 5_000,
  diagnostic_max_entries_per_biot: 5,
  diagnostic_max_entry_bytes: 65_536,
  runtime_log_max_bytes: 1_048_576

config :biot_node, Biot.Node.Repo,
  foreign_keys: :on,
  busy_timeout: 5_000,
  journal_mode: :wal,
  pool_size: 5

config :biot_server, Biot.Server.Repo, foreign_keys: :on

config :biot_web, trusted_edge_peers: []

config :biot_web, BiotWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    # The first format answers a request with no Accept header, such as an API client's. Browsers
    # ask for HTML.
    formats: [json: BiotWeb.ErrorJSON, html: BiotWeb.ErrorHTML],
    layout: false
  ],
  pubsub_server: BiotWeb.PubSub,
  live_view: [signing_salt: "LuqyvXnD"]

config :esbuild,
  version: "0.25.4",
  biot_web: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/assets/* --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../apps/biot_web/assets", __DIR__),
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
    :environment_id,
    :client_address
  ]

config :phoenix, :json_library, Jason

# Secret and credential values, and login codes and their state, never reach request logs.
config :phoenix, :filter_parameters, ["password", "value", "code", "state", "challenge"]

import_config "#{config_env()}.exs"
