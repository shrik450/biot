import Config

# Ecto logs every query at debug, which buries the warnings a test run should show. Some tests
# capture info logs, so the level stays at info.
config :logger, level: :info

config :biot_server, Biot.Server.Repo,
  database: Path.expand("../_build/test/biot_server_test.sqlite3", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox

config :biot_server, expiry_sweep_interval_ms: nil, auth_check_interval_ms: nil

config :biot_web, BiotWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Xpejv1jxyCS+IgiREufELTFm1QtRZBxZQSQX5HQNB+lnY3P7iGxKNDMId3XFv1Lv",
  server: false
