Code.require_file(Path.expand("mix/test_env.exs", __DIR__))

defmodule Biot.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      # Phoenix's code reloader recompiles through this listener. Without it every request in
      # development answers with a stack trace telling you to add it.
      listeners: [Phoenix.CodeReloader],
      deps: deps(),
      aliases: aliases(),
      releases: releases()
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      # The server migrates its database at boot, so a dropped database is a fresh one.
      test: [&Biot.Mix.TestEnv.require_test_env!/1, "ecto.drop --quiet", "test"],
      check: [
        "format --check-formatted",
        "credo --strict",
        "compile --warnings-as-errors --force",
        "biot.check_cli_error_vocabulary"
      ]
    ]
  end

  defp releases do
    [
      server: [
        applications: [
          biot_protocol: :permanent,
          biot_server: :permanent,
          biot_web: :permanent
        ],
        steps: [&build_server_assets/1, :assemble, &verify_server_assets/1],
        runtime_config_path: "config/releases/server.exs"
      ],
      node: [
        applications: [
          biot_protocol: :permanent,
          biot_node: :permanent
        ],
        runtime_config_path: "config/releases/node.exs"
      ]
    ]
  end

  defp build_server_assets(%Mix.Release{} = release) do
    Mix.Project.in_project(:biot_web, "apps/biot_web", fn _project ->
      Mix.Task.run("assets.deploy")
    end)

    release
  end

  defp verify_server_assets(%Mix.Release{} = release) do
    static_dir = release_static_dir(release)

    required = [
      "cache_manifest.json",
      "assets/css/app-*.css",
      "assets/js/app-*.js",
      "assets/vendor/ghostty-web-0.4.0-*.js",
      "assets/vendor/ghostty-vt-0.4.0-*.wasm",
      "assets/vendor/ghostty-web-0.4.0-*.LICENSE",
      "favicon-*.svg",
      "fonts/space-mono-regular-*.ttf",
      "fonts/space-mono-bold-*.ttf"
    ]

    missing =
      Enum.reject(required, fn pattern ->
        static_dir
        |> Path.join(pattern)
        |> Path.wildcard()
        |> Enum.any?(&File.regular?/1)
      end)

    if missing != [] do
      Mix.raise(
        "server release is missing required static outputs under #{static_dir}: " <>
          Enum.join(missing, ", ")
      )
    end

    release
  end

  defp release_static_dir(%Mix.Release{} = release) do
    web = Map.fetch!(release.applications, :biot_web)
    web_version = web[:vsn] |> to_string()
    Path.join([release.path, "lib", "biot_web-#{web_version}", "priv", "static"])
  end
end
