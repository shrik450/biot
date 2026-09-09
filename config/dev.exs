import Config

config :biot_server, Biot.Server.Repo,
  database: Path.expand("../biot_dev.sqlite3", __DIR__),
  pool_size: 1

config :biot_web, BiotWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "W1m+rsVfHEhnziKOrruGUxsBv3D/tWRY7hFM6eLoH1cDdWZSfaXXh8DKImNZCTz8",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:biot_web, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:biot_web, ~w(--watch)]}
  ]
