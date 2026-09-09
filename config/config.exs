import Config

config :biot_server,
  ecto_repos: [Biot.Server.Repo],
  default_node_id: nil,
  control_port: nil,
  control_tls: nil,
  handshake_timeout_ms: 10_000,
  heartbeat_interval_ms: 30_000,
  heartbeat_timeout_ms: 10_000,
  diagnostic_timeout_ms: 10_000,
  diagnostic_max_bytes: 256_000,
  max_frame_bytes: 1_000_000

config :biot_node,
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
  diagnostic_max_entries: 100,
  diagnostic_max_entry_bytes: 1_000_000

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
