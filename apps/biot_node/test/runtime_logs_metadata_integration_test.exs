defmodule Biot.Node.RuntimeLogs.MetadataIntegrationTest do
  use ExUnit.Case, async: true

  alias Biot.Node.Host.Config
  alias Biot.Node.Host.Paths
  alias Biot.Node.RuntimeLogs.Metadata
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.IncarnationId
  alias Biot.Protocol.Platform

  setup do
    root = temporary_directory("runtime-log-metadata")
    on_exit(fn -> File.rm_rf!(root) end)
    %{config: config(root), biot_id: id(BiotId), incarnation_id: id(IncarnationId)}
  end

  test "metadata round-trips its incarnation and truncation flag", context do
    assert :ok = Metadata.write(context.config, context.biot_id, context.incarnation_id, true)
    assert Metadata.read(context.config, context.biot_id) == {:ok, {context.incarnation_id, true}}
  end

  test "metadata rejects missing and extra keys, bad incarnations, and non-boolean flags",
       context do
    path = Paths.runtime_log_metadata(context.config, context.biot_id)

    invalid = [
      %{"incarnation_id" => to_string(context.incarnation_id)},
      %{"truncated" => false},
      %{"incarnation_id" => to_string(context.incarnation_id), "truncated" => false, "x" => 1},
      %{"incarnation_id" => "bad", "truncated" => false},
      %{"incarnation_id" => to_string(context.incarnation_id), "truncated" => "false"}
    ]

    for value <- invalid do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode!(value))
      assert {:error, _reason} = Metadata.read(context.config, context.biot_id)
    end
  end

  defp config(root) do
    {:ok, platform} = Platform.parse("x86_64-linux")

    struct!(Config,
      data_root: root,
      fetch_ca_bundle: nil,
      uid_range_base: 100_000,
      uid_range_count: 1_024,
      uid_range_limit: 165_536,
      git_executable: "git",
      podman_executable: "podman",
      setsid_executable: "setsid",
      mkfifo_executable: "mkfifo",
      head_executable: "head",
      cat_executable: "cat",
      sleep_executable: "sleep",
      podman_network_command: "slirp4netns",
      builder_image: "example.test/nix@sha256:#{String.duplicate("a", 64)}",
      build_support_dir: "/source",
      binary_cache_urls: ["https://cache.example.test"],
      binary_cache_keys: ["cache.example.test:key"],
      nixpkgs_repository: "https://github.com/NixOS/nixpkgs",
      nixpkgs_ref: "nixos-unstable",
      command_timeout_ms: 1_000,
      worker_timeout_ms: 2_000,
      command_max_output_bytes: 1_000,
      command_max_stderr_bytes: 1_000,
      runtime_log_max_bytes: 1_000,
      platform: platform
    )
  end

  defp id(module) do
    {:ok, value} = module.parse(Ecto.UUID.generate())
    value
  end

  defp temporary_directory(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end
end
