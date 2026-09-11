defmodule Biot.Node.DiagnosticsIntegrationTest do
  @moduledoc false
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Biot.Node.Diagnostic
  alias Biot.Node.Diagnostics
  alias Biot.Node.Host.Config
  alias Biot.Node.Host.Paths
  alias Biot.Node.Journal.Schema.Diagnostic, as: DiagnosticRow
  alias Biot.Node.Repo
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.Platform

  @moduletag :linux
  @stored_limit 65_536
  @entry_limit 5

  setup_all do
    data_root = temporary_directory("biot-diagnostics")
    previous = configure(data_root)
    start_supervised!(Repo)
    migrations = Application.app_dir(:biot_node, "priv/repo/migrations")
    Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false)

    on_exit(fn ->
      restore(previous)
      File.rm_rf!(data_root)
    end)

    {:ok, data_root: data_root}
  end

  setup do
    Repo.delete_all(DiagnosticRow)
    :ok
  end

  test "put and fetch preserve source truncation and apply a smaller read bound", context do
    biot_id = id()
    exact = Diagnostics.put(biot_id, 1, :prepare, Diagnostic.text("0123456789"))

    assert Diagnostics.fetch(exact, 10) == {:ok, {"0123456789", false}}
    assert Diagnostics.fetch(exact, 4) == {:ok, {"0123", true}}

    oversized =
      Diagnostics.put(
        biot_id,
        2,
        :install,
        {:binary.copy("a", @stored_limit + 1), true}
      )

    assert {:ok, {content, true}} = Diagnostics.fetch(oversized, @stored_limit + 100)
    assert byte_size(content) == @stored_limit
    assert File.stat!(diagnostic_path(context.data_root, oversized)).size == @stored_limit
  end

  test "same-key put replaces the file and row", context do
    biot_id = id()
    first = Diagnostics.put(biot_id, 4, :start, Diagnostic.text("first attempt"))
    first_path = diagnostic_path(context.data_root, first)
    second = Diagnostics.put(biot_id, 4, :start, Diagnostic.text("second attempt"))

    assert Diagnostics.fetch(first, 100) == :not_found
    refute File.exists?(first_path)
    assert Diagnostics.fetch(second, 100) == {:ok, {"second attempt", false}}
    assert Repo.aggregate(DiagnosticRow, :count) == 1
  end

  test "retention keeps the latest entries without affecting another Biot" do
    biot_id = id()
    other_biot = id()
    other = Diagnostics.put(other_biot, 1, :start, Diagnostic.text("other"))

    entries =
      for revision <- 1..(@entry_limit + 1),
          do: Diagnostics.put(biot_id, revision, :start, Diagnostic.text("r#{revision}"))

    assert Diagnostics.fetch(hd(entries), 100) == :not_found

    for {entry, revision} <- Enum.zip(tl(entries), 2..(@entry_limit + 1)) do
      assert Diagnostics.fetch(entry, 100) == {:ok, {"r#{revision}", false}}
    end

    assert Diagnostics.fetch(other, 100) == {:ok, {"other", false}}
  end

  test "a missing content file reads as not found", context do
    diagnostic_id = Diagnostics.put(id(), 1, :resolve, Diagnostic.text("gone"))
    File.rm!(diagnostic_path(context.data_root, diagnostic_id))
    assert Diagnostics.fetch(diagnostic_id, 100) == :not_found
  end

  test "forget removes every file for the Biot", context do
    biot_id = id()

    entries =
      for revision <- 1..3,
          do: Diagnostics.put(biot_id, revision, :start, Diagnostic.text("r#{revision}"))

    assert :ok = Diagnostics.forget(biot_id)
    assert Enum.all?(entries, &(Diagnostics.fetch(&1, 100) == :not_found))
    refute Enum.any?(entries, &File.exists?(diagnostic_path(context.data_root, &1)))
  end

  test "a stale path that cannot be unlinked is logged and does not stop replacement", context do
    biot_id = id()
    first = Diagnostics.put(biot_id, 1, :start, Diagnostic.text("old"))
    first_path = diagnostic_path(context.data_root, first)
    File.rm!(first_path)
    File.mkdir!(first_path)

    log =
      capture_log(fn ->
        second = Diagnostics.put(biot_id, 1, :start, Diagnostic.text("new"))
        assert Diagnostics.fetch(second, 100) == {:ok, {"new", false}}
      end)

    assert log =~ "could not remove diagnostic file"
    File.rmdir!(first_path)
  end

  defp configure(data_root) do
    project_root = Path.expand("../../..", __DIR__)

    settings = [
      data_root: data_root,
      uid_range_base: 100_000,
      uid_range_count: 1_024,
      uid_range_limit: 165_536,
      setsid_executable: "setsid",
      mkfifo_executable: "mkfifo",
      head_executable: "head",
      cat_executable: "cat",
      sleep_executable: "sleep",
      podman_network_command: "slirp4netns",
      builder_image: "example.test/nix@sha256:#{String.duplicate("a", 64)}",
      build_support_dir: project_root,
      binary_cache_urls: ["https://cache.example.test"],
      binary_cache_keys: ["cache.example.test:key"],
      host_command_timeout_ms: 1_000,
      worker_timeout_ms: 2_000,
      host_command_max_output_bytes: 1_000,
      host_command_max_stderr_bytes: 1_000,
      runtime_log_max_bytes: 1_000,
      diagnostic_max_entry_bytes: @stored_limit,
      diagnostic_max_entries_per_biot: @entry_limit
    ]

    previous =
      Map.new(settings, fn {key, _value} -> {key, Application.get_env(:biot_node, key)} end)

    Enum.each(settings, fn {key, value} -> Application.put_env(:biot_node, key, value) end)
    previous
  end

  defp restore(previous) do
    Enum.each(previous, fn
      {key, nil} -> Application.delete_env(:biot_node, key)
      {key, value} -> Application.put_env(:biot_node, key, value)
    end)
  end

  defp diagnostic_path(data_root, diagnostic_id) do
    Paths.diagnostic(config(data_root), diagnostic_id)
  end

  defp config(data_root) do
    {:ok, platform} = Platform.parse("x86_64-linux")

    struct!(Config,
      data_root: data_root,
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

  defp id do
    {:ok, id} = BiotId.parse(Ecto.UUID.generate())
    id
  end

  defp temporary_directory(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end
end
