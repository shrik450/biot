defmodule Biot.Node.HostJournalIntegrationTest do
  use ExUnit.Case, async: false

  import Biot.Node.ReconcileFixtures

  alias Biot.Node.Allocation
  alias Biot.Node.Host
  alias Biot.Node.Host.Config
  alias Biot.Node.Host.Context
  alias Biot.Node.Journal
  alias Biot.Node.Journal.Schema.Allocation, as: AllocationRow
  alias Biot.Node.NetworkId
  alias Biot.Node.NodePrivatePath
  alias Biot.Node.Repo
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.Platform

  setup_all do
    data_root = temporary_directory("biot-node-journal")
    previous = Application.get_env(:biot_node, :data_root)
    Application.put_env(:biot_node, :data_root, data_root)

    start_supervised!(Repo)
    migrations = Application.app_dir(:biot_node, "priv/repo/migrations")
    Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false)

    on_exit(fn ->
      File.rm_rf!(data_root)

      if previous,
        do: Application.put_env(:biot_node, :data_root, previous),
        else: Application.delete_env(:biot_node, :data_root)
    end)

    {:ok, data_root: data_root}
  end

  setup do
    Repo.delete_all(Biot.Node.Journal.Schema.Installation)
    Repo.delete_all(Biot.Node.Journal.Schema.Resolution)
    Repo.delete_all(AllocationRow)
    :ok
  end

  test "the first unused UID range fills a gap before extending the journal", context do
    assert {:ok, _allocation} = Journal.put_allocation(allocation(context.data_root, 1, 100_000))
    assert {:ok, _allocation} = Journal.put_allocation(allocation(context.data_root, 2, 102_048))

    assert Journal.next_uid_start(100_000, 1_024, 103_072) == {:ok, 101_024}
    assert Journal.next_uid_start(100_000, 1_024, 102_048) == {:ok, 101_024}

    assert {:ok, _allocation} = Journal.put_allocation(allocation(context.data_root, 3, 101_024))
    assert Journal.next_uid_start(100_000, 1_024, 103_072) == {:error, :uid_ranges_exhausted}
  end

  test "release_allocation returns a typed error while owned records remain", context do
    allocation = allocation(context.data_root, 1, 100_000)
    assert {:ok, allocation} = Journal.put_allocation(allocation)
    assert {:ok, _resolution} = Journal.put_resolution(allocation.biot_id, e1(), manifest())

    assert Journal.delete_allocation(allocation) == {:error, :records_remain}
    assert Journal.allocation(allocation.biot_id) == allocation
  end

  test "the database restricts direct allocation deletion when a resolution remains", context do
    allocation = allocation(context.data_root, 1, 100_000)
    assert {:ok, _allocation} = Journal.put_allocation(allocation)
    assert {:ok, _resolution} = Journal.put_resolution(allocation.biot_id, e1(), manifest())

    row = Repo.get!(AllocationRow, allocation.biot_id)
    assert_raise Ecto.ConstraintError, fn -> Repo.delete!(row) end
    assert Journal.allocation(allocation.biot_id) == allocation
  end

  test "the database restricts direct allocation deletion when an installation remains",
       context do
    allocation = allocation(context.data_root, 1, 100_000)
    assert {:ok, _allocation} = Journal.put_allocation(allocation)
    assert {:ok, _installation} = Journal.put_installation(allocation, e1(), artifact(e1()))

    row = Repo.get!(AllocationRow, allocation.biot_id)
    assert_raise Ecto.ConstraintError, fn -> Repo.delete!(row) end
    assert Journal.allocation(allocation.biot_id) == allocation
  end

  test "release_environment rejects an environment owned by another biot", context do
    owner = allocation(context.data_root, 1, 100_000)
    caller = allocation(context.data_root, 2, 101_024)
    assert {:ok, _allocation} = Journal.put_allocation(owner)
    assert {:ok, _allocation} = Journal.put_allocation(caller)
    assert {:ok, _resolution} = Journal.put_resolution(owner.biot_id, e1(), manifest())

    action = {:release_environment, e1()}
    host_context = %Context{biot_id: caller.biot_id, config: config(context.data_root)}

    assert {:error, %Biot.Node.Host.Outcome{outcome: :ownership_mismatch}} =
             Host.run(action, host_context)

    assert Journal.resolution(owner.biot_id, e1())
  end

  defp allocation(data_root, number, uid_start) do
    biot_id = id(BiotId, number)
    {:ok, private_path} = NodePrivatePath.parse(Path.join(data_root, "biot-#{number}"))

    %Allocation{
      biot_id: biot_id,
      uid_range: %{start: uid_start, count: 1_024},
      data_root: private_path,
      network_id: NetworkId.from_biot_id(biot_id),
      initialization: :uninitialized
    }
  end

  defp config(data_root) do
    {:ok, platform} = Platform.parse("x86_64-linux")
    project_root = Path.expand("../../..", __DIR__)

    struct!(Config,
      data_root: data_root,
      uid_range_base: 100_000,
      uid_range_count: 1_024,
      uid_range_limit: 165_536,
      git_executable: "git",
      nix_executable: "nix",
      nix_instantiate_executable: "nix-instantiate",
      podman_executable: "podman",
      setsid_executable: "setsid",
      podman_network_command: "slirp4netns",
      nix_build_file: Path.join(project_root, "nix/build.nix"),
      nix_pin_file: Path.join(project_root, "nix/pin.nix"),
      nixpkgs_repository: "https://github.com/NixOS/nixpkgs",
      nixpkgs_ref: "nixos-unstable",
      command_timeout_ms: 120_000,
      command_max_output_bytes: 64_000,
      platform: platform
    )
  end

  defp id(module, number) do
    value =
      "00000000-0000-4000-8000-#{number |> Integer.to_string() |> String.pad_leading(12, "0")}"

    {:ok, parsed} = module.parse(value)
    parsed
  end

  defp temporary_directory(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end
end
