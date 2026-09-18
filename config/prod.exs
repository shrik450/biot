import Config

config :logger, level: :info

config :biot_web, BiotWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

config :biot_web, BiotWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    # Health checks arrive over plain HTTP from an orchestrator that does not go through the edge,
    # so the path reaches the app instead of a redirect to the control host.
    exclude: [
      hosts: ["localhost", "127.0.0.1"],
      paths: ["/health"]
    ]
  ]
