import Config

config :biot_web, BiotWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

config :biot_web, BiotWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [
      hosts: ["localhost", "127.0.0.1"]
    ]
  ]
