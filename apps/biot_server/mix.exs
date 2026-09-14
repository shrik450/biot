Code.require_file(Path.expand("../../mix/test_env.exs", __DIR__))

defmodule Biot.Server.MixProject do
  use Mix.Project

  def project do
    [
      app: :biot_server,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixirc_paths: elixirc_paths(Mix.env()),
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Biot.Server.Application, []}
    ]
  end

  defp deps do
    [
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, "~> 0.22"},
      {:jason, "~> 1.4"},
      {:oidcc, "~> 3.9"},
      {:phoenix_pubsub, "~> 2.1"},
      {:thousand_island, "~> 1.5"},
      {:stream_data, "~> 1.1", only: :test},
      {:biot_node, in_umbrella: true, only: :test},
      {:biot_protocol, in_umbrella: true}
    ]
  end

  defp aliases do
    [
      test: [
        &Biot.Mix.TestEnv.require_test_env!/1,
        "ecto.drop --quiet",
        "ecto.create --quiet",
        "ecto.migrate --quiet",
        "test"
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end
