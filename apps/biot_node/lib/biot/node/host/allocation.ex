defmodule Biot.Node.Host.Allocation do
  @moduledoc "Inspects and changes an allocation's network and private working data."

  alias Biot.Node.Allocation
  alias Biot.Node.Host.Command
  alias Biot.Node.Host.Config
  alias Biot.Node.Host.Container
  alias Biot.Node.Host.Context
  alias Biot.Node.Host.DataInspection
  alias Biot.Node.Host.FileSystem
  alias Biot.Node.Host.Network
  alias Biot.Node.Host.Outcome
  alias Biot.Node.Host.Paths
  alias Biot.Node.Journal
  alias Biot.Node.MarkerId
  alias Biot.Node.NetworkId
  alias Biot.Node.NodePrivatePath
  alias Biot.Protocol.RepositorySource

  @spec allocate(Context.t()) :: :ok | {:error, Outcome.t()}
  def allocate(%Context{biot_id: biot_id, config: config}) do
    case Journal.allocation(biot_id) do
      nil -> allocate_new(config, biot_id)
      %Allocation{} = allocation -> prepare_allocation(config, allocation)
    end
  end

  @spec state(Config.t(), Allocation.t()) :: Biot.Node.NodeState.data_state()
  def state(config, %Allocation{} = allocation) do
    facts = %{
      allocation_directory: FileSystem.directory(Paths.biot(config, allocation.biot_id)),
      mounts: mount_facts(config, allocation),
      marker: marker_fact(config, allocation)
    }

    DataInspection.state(allocation, facts)
  end

  @spec initialize(Context.t(), Allocation.t(), RepositorySource.t()) ::
          :ok | {:error, Outcome.t()}
  def initialize(
        %Context{biot_id: biot_id, config: config},
        %Allocation{biot_id: biot_id} = allocation,
        repository
      ) do
    with {:ok, _network} <- ensure_network(config, allocation),
         {:ok, marker_id} <- initialization_identity(config, biot_id),
         {:ok, _checkout} <- ensure_checkout(config, biot_id, repository, marker_id),
         {:ok, _mounts} <- ensure_mounts(config, allocation),
         {:ok, _marker} <- write_marker(config, biot_id, marker_id),
         {:ok, _record} <- complete_initialization(allocation, marker_id) do
      :ok
    end
  end

  @spec remove_data(Context.t(), Allocation.t()) :: :ok | {:error, Outcome.t()}
  def remove_data(
        %Context{biot_id: biot_id, config: config},
        %Allocation{biot_id: biot_id} = allocation
      ) do
    with {:ok, _ownership} <- reclaim_data(config, allocation),
         {:ok, _removed} <- remove_tree(Paths.biot(config, biot_id)),
         {:ok, _record} <- reset_initialization(allocation) do
      :ok
    end
  end

  @spec release(Context.t(), Allocation.t()) :: :ok | {:error, Outcome.t()}
  def release(
        %Context{biot_id: biot_id, config: config},
        %Allocation{biot_id: biot_id} = allocation
      ) do
    directory = FileSystem.directory(Paths.biot(config, biot_id))
    container = Container.state(config, biot_id)

    release_if_absent(config, allocation, directory, container)
  end

  defp allocate_new(config, biot_id) do
    case Journal.allocation(biot_id) do
      nil ->
        with {:ok, allocation} <- planned_allocation(config, biot_id),
             {:ok, _resources} <- prepare(config, allocation) do
          insert_allocation(config, allocation)
        end

      %Allocation{} = allocation ->
        prepare_allocation(config, allocation)
    end
  end

  defp insert_allocation(config, allocation) do
    case Journal.put_allocation(allocation) do
      {:ok, _record} -> :ok
      {:error, :uid_start_conflict} -> allocate_new(config, allocation.biot_id)
      {:error, reason} -> {:error, Outcome.from_reason(reason)}
    end
  end

  defp prepare_allocation(config, allocation) do
    case prepare(config, allocation) do
      {:ok, :prepared} -> :ok
      {:error, %Outcome{} = outcome} -> {:error, outcome}
    end
  end

  defp planned_allocation(config, biot_id) do
    case Journal.next_uid_start(
           config.uid_range_base,
           config.uid_range_count,
           config.uid_range_limit
         ) do
      {:ok, uid_start} ->
        build_allocation(config, biot_id, uid_start)

      {:error, :uid_ranges_exhausted} ->
        {:error,
         Outcome.new(
           :host_unavailable,
           "all configured UID and GID ranges are allocated"
         )}
    end
  end

  defp build_allocation(config, biot_id, uid_start) do
    case NodePrivatePath.parse(Paths.biot(config, biot_id)) do
      {:ok, data_root} ->
        {:ok,
         %Allocation{
           biot_id: biot_id,
           uid_range: %{start: uid_start, count: config.uid_range_count},
           data_root: data_root,
           network_id: NetworkId.from_biot_id(biot_id),
           initialization: :uninitialized
         }}

      {:error, reason} ->
        {:error, Outcome.from_reason(reason)}
    end
  end

  defp prepare(config, allocation) do
    with {:ok, _root} <- make_directory(NodePrivatePath.to_string(allocation.data_root)),
         {:ok, _layout} <- ensure_allocation_layout(config, allocation),
         {:ok, _ownership} <-
           chown(config, allocation, [Paths.rootfs(config, allocation.biot_id)]),
         {:ok, _network} <- ensure_network(config, allocation) do
      {:ok, :prepared}
    end
  end

  defp ensure_allocation_layout(config, allocation) do
    rootfs = Paths.rootfs(config, allocation.biot_id)

    directories = [
      Path.join(rootfs, "dev"),
      Path.join(rootfs, "proc"),
      Path.join(rootfs, "sys"),
      Path.join(rootfs, "etc"),
      Path.join(rootfs, "run"),
      Path.join(rootfs, "tmp"),
      Path.join(rootfs, "nix/store"),
      Path.join(rootfs, "biot/checkout"),
      Path.join(rootfs, "biot/home"),
      Path.join(rootfs, "biot/service-data")
    ]

    case FileSystem.ensure_directories(directories) do
      :ok -> ensure_rootfs_files(rootfs)
      {:error, reason} -> {:error, Outcome.from_reason(reason)}
    end
  end

  defp ensure_rootfs_files(rootfs) do
    Enum.reduce_while(["etc/hosts", "etc/hostname", "etc/resolv.conf"], {:ok, :files}, fn
      relative, {:ok, :files} ->
        case ensure_file(Path.join(rootfs, relative)) do
          {:ok, :file} -> {:cont, {:ok, :files}}
          {:error, reason} -> {:halt, {:error, Outcome.from_reason(reason)}}
        end
    end)
  end

  defp ensure_file(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} -> {:ok, :file}
      {:ok, %File.Stat{}} -> {:error, {:not_a_file, path}}
      {:error, :enoent} -> create_file(path)
      {:error, reason} -> {:error, {reason, path}}
    end
  end

  defp create_file(path) do
    case File.touch(path) do
      :ok -> {:ok, :file}
      {:error, reason} -> {:error, {reason, path}}
    end
  end

  defp make_directory(path) do
    case File.mkdir_p(path) do
      :ok -> {:ok, :directory}
      {:error, reason} -> {:error, Outcome.from_reason(reason)}
    end
  end

  defp remove_tree(path) do
    case FileSystem.remove_tree(path) do
      :ok -> {:ok, :removed}
      {:error, reason} -> {:error, Outcome.from_reason(reason)}
    end
  end

  defp mount_facts(_config, %Allocation{initialization: :uninitialized}), do: []

  defp mount_facts(config, allocation) do
    Enum.map(Paths.mounts(config, allocation.biot_id), fn {path, _target} ->
      FileSystem.directory(path)
    end)
  end

  defp marker_fact(_config, %Allocation{initialization: :uninitialized}), do: :absent

  defp marker_fact(config, allocation) do
    FileSystem.read(Paths.marker(config, allocation.biot_id))
  end

  defp initialization_identity(config, biot_id) do
    path = Paths.initialization_identity(config, biot_id)

    case FileSystem.read(path) do
      {:present, value} -> parse_marker_identity(value)
      :absent -> write_marker_identity(path)
      {:error, reason} -> {:error, Outcome.from_reason(reason)}
    end
  end

  defp parse_marker_identity(value) do
    case MarkerId.parse(String.trim(value)) do
      {:ok, marker_id} ->
        {:ok, marker_id}

      {:error, _reason} ->
        {:error, Outcome.new(:host_unavailable, "the initialization identity is invalid")}
    end
  end

  defp write_marker_identity(path) do
    marker_id = MarkerId.generate()

    # The file keeps the marker identity stable if the effect task dies after cloning.
    case FileSystem.write_atomic(path, [MarkerId.to_string(marker_id), "\n"]) do
      :ok -> {:ok, marker_id}
      {:error, reason} -> {:error, Outcome.from_reason(reason)}
    end
  end

  defp ensure_checkout(config, biot_id, repository, marker_id) do
    checkout = Paths.checkout(config, biot_id)

    case FileSystem.directory(checkout) do
      {:present, :directory} -> {:ok, :checkout}
      :absent -> clone_checkout(config, repository, checkout, biot_id, marker_id)
      {:error, reason} -> {:error, Outcome.from_reason(reason)}
    end
  end

  defp clone_checkout(config, repository, checkout, biot_id, marker_id) do
    staging = Paths.checkout_staging(config, biot_id, MarkerId.to_string(marker_id))

    with {:ok, _removed} <- remove_tree(staging),
         {:ok, _cloned} <- clone(config, repository, staging),
         {:ok, _promoted} <- promote_checkout(staging, checkout) do
      {:ok, :checkout}
    end
  end

  defp clone(config, repository, staging) do
    result =
      command(
        config,
        config.git_executable,
        ["clone", "--", RepositorySource.to_string(repository), staging],
        env: [{"GIT_TERMINAL_PROMPT", "0"}]
      )

    case result do
      {:ok, %Command.Result{status: 0}} ->
        {:ok, :cloned}

      {:ok, %Command.Result{} = command_result} ->
        FileSystem.remove_tree(staging)
        {:error, Outcome.from_command(:invalid_source, command_result)}

      {:error, reason} ->
        FileSystem.remove_tree(staging)
        {:error, Outcome.from_reason(reason)}
    end
  end

  defp promote_checkout(staging, checkout) do
    case File.rename(staging, checkout) do
      :ok ->
        {:ok, :promoted}

      {:error, :eexist} ->
        # A prior attempt may publish the same stable checkout before its task reports completion.
        case FileSystem.remove_tree(staging) do
          :ok -> {:ok, :promoted}
          {:error, reason} -> {:error, Outcome.from_reason(reason)}
        end

      {:error, reason} ->
        FileSystem.remove_tree(staging)
        {:error, Outcome.from_reason(reason)}
    end
  end

  defp ensure_mounts(config, allocation) do
    paths = Enum.map(Paths.mounts(config, allocation.biot_id), &elem(&1, 0))

    case FileSystem.ensure_directories(paths) do
      :ok -> chown(config, allocation, paths)
      {:error, reason} -> {:error, Outcome.from_reason(reason)}
    end
  end

  defp chown(config, allocation, paths) do
    case owned_by_all?(paths, allocation.uid_range.start) do
      {:ok, true} -> {:ok, :owned}
      {:ok, false} -> change_ownership(config, allocation, paths)
      {:error, reason} -> {:error, Outcome.from_reason(reason)}
    end
  end

  defp owned_by_all?(paths, owner) do
    Enum.reduce_while(paths, {:ok, true}, fn path, {:ok, true} ->
      case File.stat(path) do
        {:ok, %File.Stat{uid: ^owner, gid: ^owner}} -> {:cont, {:ok, true}}
        {:ok, %File.Stat{}} -> {:halt, {:ok, false}}
        {:error, reason} -> {:halt, {:error, {reason, path}}}
      end
    end)
  end

  defp change_ownership(config, allocation, paths) do
    mapped_start = Allocation.subordinate_start(allocation, config.uid_range_base)
    owner = "#{mapped_start}:#{mapped_start}"

    case command(config, config.podman_executable, ["unshare", "chown", "-R", owner | paths]) do
      {:ok, %Command.Result{status: 0}} ->
        {:ok, :owned}

      {:ok, %Command.Result{} = result} ->
        {:error, Outcome.from_command(:host_unavailable, result)}

      {:error, reason} ->
        {:error, Outcome.from_reason(reason)}
    end
  end

  defp reclaim_data(config, allocation) do
    path = Paths.biot(config, allocation.biot_id)

    case FileSystem.directory(path) do
      :absent ->
        {:ok, :absent}

      {:present, :directory} ->
        case command(config, config.podman_executable, ["unshare", "chown", "-R", "0:0", path]) do
          {:ok, %Command.Result{status: 0}} ->
            {:ok, :owned}

          {:ok, %Command.Result{} = result} ->
            {:error, Outcome.from_command(:host_unavailable, result)}

          {:error, reason} ->
            {:error, Outcome.from_reason(reason)}
        end

      {:error, reason} ->
        {:error, Outcome.from_reason(reason)}
    end
  end

  defp write_marker(config, biot_id, marker_id) do
    path = Paths.marker(config, biot_id)
    content = [MarkerId.to_string(marker_id), "\n"]

    case FileSystem.read(path) do
      :absent ->
        case FileSystem.write_atomic(path, content) do
          :ok -> {:ok, :written}
          {:error, reason} -> {:error, Outcome.from_reason(reason)}
        end

      {:present, existing} ->
        if existing == IO.iodata_to_binary(content),
          do: {:ok, :present},
          else: {:error, Outcome.new(:host_unavailable, "the initialization marker changed")}

      {:error, reason} ->
        {:error, Outcome.from_reason(reason)}
    end
  end

  defp complete_initialization(allocation, marker_id) do
    case Journal.complete_initialization(allocation, marker_id) do
      {:ok, record} -> {:ok, record}
      {:error, :stale} -> {:ok, :stale}
      {:error, reason} -> {:error, Outcome.from_reason(reason)}
    end
  end

  defp reset_initialization(allocation) do
    case Journal.reset_initialization(allocation) do
      :ok -> {:ok, :reset}
      {:error, :stale} -> {:ok, :stale}
      {:error, reason} -> {:error, Outcome.from_reason(reason)}
    end
  end

  defp ensure_network(config, allocation) do
    case Network.ensure(config, allocation.network_id) do
      :ok -> {:ok, :network}
      {:error, %Outcome{} = outcome} -> {:error, outcome}
    end
  end

  defp release_if_absent(config, allocation, :absent, :absent) do
    with {:ok, _network} <- remove_network(config, allocation),
         {:ok, _record} <- delete_allocation(allocation) do
      :ok
    end
  end

  defp release_if_absent(_config, allocation, _directory, {:present, container})
       when container.biot_id != allocation.biot_id do
    {:error, Outcome.new(:ownership_mismatch)}
  end

  defp release_if_absent(_config, _allocation, {:error, reason}, _container) do
    {:error, Outcome.from_reason(reason)}
  end

  defp release_if_absent(_config, _allocation, _directory, {:unknown, failure}) do
    {:error, Outcome.from_reason(failure)}
  end

  defp release_if_absent(_config, _allocation, _directory, _container), do: :ok

  defp remove_network(config, allocation) do
    case Network.remove(config, allocation.network_id) do
      :ok -> {:ok, :removed}
      {:error, %Outcome{} = outcome} -> {:error, outcome}
    end
  end

  defp delete_allocation(allocation) do
    case Journal.delete_allocation(allocation) do
      :ok ->
        {:ok, :deleted}

      {:error, :stale} ->
        {:ok, :stale}

      {:error, :records_remain} ->
        {:error, Outcome.new(:host_unavailable, "the allocation still has journal records")}

      {:error, reason} ->
        {:error, Outcome.from_reason(reason)}
    end
  end

  defp command(config, executable, arguments, options \\ []) do
    Command.run(
      config.setsid_executable,
      executable,
      arguments,
      Keyword.merge(
        [
          timeout_ms: config.command_timeout_ms,
          max_output_bytes: config.command_max_output_bytes
        ],
        options
      )
    )
  end
end
