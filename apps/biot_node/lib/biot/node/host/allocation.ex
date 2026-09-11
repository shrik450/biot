defmodule Biot.Node.Host.Allocation do
  @moduledoc "Inspects and changes an allocation's network and private working data."

  alias Biot.Node.Allocation
  alias Biot.Node.Diagnostic
  alias Biot.Node.Host.Command
  alias Biot.Node.Host.Config
  alias Biot.Node.Host.Container
  alias Biot.Node.Host.Context
  alias Biot.Node.Host.DataInspection
  alias Biot.Node.Host.FileSystem
  alias Biot.Node.Host.Git
  alias Biot.Node.Host.Network
  alias Biot.Node.Host.Outcome
  alias Biot.Node.Host.Paths
  alias Biot.Node.Host.Podman
  alias Biot.Node.Host.Worker
  alias Biot.Node.Journal
  alias Biot.Node.NetworkId
  alias Biot.Node.NodePrivatePath
  alias Biot.Protocol.BiotId
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
         {:ok, _checkout} <- ensure_checkout(config, biot_id, repository),
         {:ok, _mounts} <- ensure_owned(config, allocation, owned_directories(config, biot_id)),
         {:ok, _marker} <- write_marker(config, biot_id),
         {:ok, _record} <- complete_initialization(allocation) do
      :ok
    end
  end

  @spec remove_data(Context.t(), Allocation.t()) :: :ok | {:error, Outcome.t()}
  def remove_data(
        %Context{biot_id: biot_id, config: config},
        %Allocation{biot_id: biot_id} = allocation
      ) do
    with :ok <- Worker.cancel(config, biot_id),
         :ok <- Podman.reclaim(config, Paths.biot(config, biot_id)),
         {:ok, _removed} <- remove_tree(Paths.biot(config, biot_id)),
         {:ok, _record} <- reset_initialization(allocation) do
      :ok
    end
  end

  @doc """
  Gives back the UID range once nothing can still be using it.

  The worker comes first: a range whose build worker is still running is a range a new allocation
  would share, so release ends that worker and confirms its absence before it looks at anything
  else.
  """
  @spec release(Context.t(), Allocation.t()) :: :ok | {:error, Outcome.t()}
  def release(
        %Context{biot_id: biot_id, config: config},
        %Allocation{biot_id: biot_id} = allocation
      ) do
    with :ok <- Worker.cancel(config, biot_id) do
      directory = FileSystem.directory(Paths.biot(config, biot_id))
      container = Container.state(config, biot_id)

      release_if_absent(config, allocation, directory, container)
    end
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
           Diagnostic.text("all configured UID and GID ranges are allocated")
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
    biot_id = allocation.biot_id

    with {:ok, _root} <- make_directory(NodePrivatePath.to_string(allocation.data_root)),
         {:ok, _support} <- make_directory(Paths.build_support(config, biot_id)),
         {:ok, _environments} <- make_directory(Paths.environments(config, biot_id)),
         {:ok, _mounts} <-
           ensure_owned(config, allocation, Paths.allocation_owned_directories(config, biot_id)),
         {:ok, _network} <- ensure_network(config, allocation) do
      {:ok, :prepared}
    end
  end

  # The checkout joins the owned set only once it exists, because its absence is what marks the
  # clone still to do.
  defp owned_directories(config, biot_id) do
    [Paths.checkout(config, biot_id) | Paths.allocation_owned_directories(config, biot_id)]
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
    Enum.map(owned_directories(config, allocation.biot_id), &FileSystem.directory/1)
  end

  defp marker_fact(_config, %Allocation{initialization: :uninitialized}), do: :absent

  defp marker_fact(config, allocation) do
    FileSystem.read(Paths.marker(config, allocation.biot_id))
  end

  defp ensure_checkout(config, biot_id, repository) do
    checkout = Paths.checkout(config, biot_id)

    case FileSystem.directory(checkout) do
      {:present, :directory} -> {:ok, :checkout}
      :absent -> clone_checkout(config, repository, checkout, biot_id)
      {:error, reason} -> {:error, Outcome.from_reason(reason)}
    end
  end

  defp clone_checkout(config, repository, checkout, biot_id) do
    staging = Paths.checkout_staging(config, biot_id)

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
        Git.clone_arguments(config, repository, staging),
        env: Git.environment()
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

  defp ensure_owned(config, allocation, paths) do
    with :ok <- FileSystem.ensure_directories(paths),
         :ok <- Podman.grant(config, allocation, paths) do
      {:ok, :owned}
    else
      {:error, %Outcome{} = outcome} -> {:error, outcome}
      {:error, reason} -> {:error, Outcome.from_reason(reason)}
    end
  end

  # The marker says which biot owns the promoted data, so writing it again writes the same bytes
  # and a repeated initialization converges.
  defp write_marker(config, biot_id) do
    content = [BiotId.to_string(biot_id), "\n"]

    case FileSystem.write_atomic(Paths.marker(config, biot_id), content) do
      :ok -> {:ok, :written}
      {:error, reason} -> {:error, Outcome.from_reason(reason)}
    end
  end

  defp complete_initialization(allocation) do
    case Journal.complete_initialization(allocation) do
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
        {:error,
         Outcome.new(
           :host_unavailable,
           Diagnostic.text("the allocation still has journal records")
         )}

      {:error, reason} ->
        {:error, Outcome.from_reason(reason)}
    end
  end

  defp command(config, executable, arguments, options) do
    Command.run(
      config.setsid_executable,
      Config.capture_tools(config),
      executable,
      arguments,
      Keyword.merge(
        [
          timeout_ms: config.command_timeout_ms,
          max_output_bytes: config.command_max_output_bytes,
          max_stderr_bytes: config.command_max_stderr_bytes
        ],
        options
      )
    )
  end
end
