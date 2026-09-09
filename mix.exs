defmodule Biot.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
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
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      check: [
        "format --check-formatted",
        "credo --strict",
        "compile --warnings-as-errors --force"
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
        ]
      ],
      node: [
        applications: [
          biot_protocol: :permanent,
          biot_node: :permanent
        ]
      ]
    ]
  end
end
