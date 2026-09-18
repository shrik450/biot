defmodule Biot.Node.Host.Container do
  @moduledoc """
  Runs and inspects the one rootless Podman runtime container an allocation owns.

  The container's name derives from the Biot ID, so it is the same for every incarnation and a
  lost create reply needs no remembered ID: inspection resolves the name to Podman's native ID.
  Retirement removes that exact ID, so a later incarnation under the same name is never the one
  removed. Ownership labels keep a container that someone else gave the same name from being
  adopted or removed.
  """

  alias Biot.Node.Allocation
  alias Biot.Node.Diagnostic
  alias Biot.Node.Host.Command
  alias Biot.Node.Host.Config
  alias Biot.Node.Host.ContainerInspection
  alias Biot.Node.Host.Context
  alias Biot.Node.Host.Diagnostic, as: HostDiagnostic
  alias Biot.Node.Host.Environment
  alias Biot.Node.Host.Names
  alias Biot.Node.Host.Network
  alias Biot.Node.Host.Outcome
  alias Biot.Node.Host.Paths
  alias Biot.Node.Host.Podman
  alias Biot.Node.Host.PrivateStore
  alias Biot.Node.Installation
  alias Biot.Node.StorePath
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.IncarnationId

  @type resource :: Biot.Node.NodeState.resource(Biot.Node.NodeState.container())

  @spec state(Config.t(), BiotId.t()) :: resource()
  def state(config, biot_id) do
    name = Names.container(biot_id)

    case Podman.exists(config, :container, name) do
      :absent -> :absent
      :present -> inspect_present(config, name)
      {:error, %Command.Result{} = result} -> unknown_from(result)
      {:error, reason} -> unreachable(reason)
    end
  end

  @spec start(Context.t(), Allocation.t(), Installation.t()) ::
          :ok | {:error, Outcome.t()}
  def start(
        %Context{biot_id: biot_id, config: config},
        %Allocation{biot_id: biot_id} = allocation,
        %Installation{biot_id: biot_id} = installation
      ) do
    with {:ok, bundle} <- Environment.bundle(config, biot_id, installation.environment_id),
         {:ok, _network} <- ensure_network(config, allocation),
         {:ok, _container} <- create(config, allocation, installation, bundle),
         do: :ok
  end

  @spec retire(Context.t(), IncarnationId.t()) :: :ok | {:error, Outcome.t()}
  def retire(%Context{biot_id: biot_id, config: config}, incarnation_id) do
    case state(config, biot_id) do
      :absent ->
        :ok

      {:present, %{biot_id: owner}} when owner != biot_id ->
        {:error, Outcome.new(:ownership_mismatch)}

      {:present, %{incarnation_id: ^incarnation_id}} ->
        remove(config, incarnation_id)

      {:present, _later_incarnation} ->
        :ok

      {:unknown, failure} ->
        {:error, Outcome.from_reason(failure)}
    end
  end

  # A container removed between the two commands reads as unknown, and reconciliation inspects
  # again.
  defp inspect_present(config, name) do
    case Podman.run(config, ["container", "inspect", name]) do
      {:ok, %Command.Result{status: 0, stdout: stdout}} -> parse_inspection(stdout, config)
      {:ok, %Command.Result{} = result} -> unknown_from(result)
      {:error, reason} -> unreachable(reason)
    end
  end

  defp parse_inspection(stdout, config) do
    with {:ok, [value]} <- Jason.decode(stdout),
         {:ok, container} <- ContainerInspection.parse(value) do
      present_or_starting(config, container)
    else
      _error ->
        unknown(:unreadable, Diagnostic.text("Podman returned invalid container JSON"))
    end
  end

  defp present_or_starting(config, %{state: :running} = container) do
    state = if agent_reachable?(config, container.biot_id), do: :running, else: :starting
    {:present, %{container | state: state}}
  end

  defp present_or_starting(_config, container), do: {:present, container}

  defp agent_reachable?(config, biot_id) do
    path = Paths.agent_socket(config, biot_id)

    case :socket.open(:local, :stream, :default) do
      {:ok, socket} ->
        reachable = :socket.connect(socket, %{family: :local, path: path}) == :ok
        _ = :socket.close(socket)
        reachable

      {:error, _reason} ->
        false
    end
  end

  defp create(config, allocation, installation, bundle) do
    case state(config, allocation.biot_id) do
      :absent -> run_container(config, allocation, installation, bundle)
      {:present, container} -> verify_started(container, allocation, installation)
      {:unknown, failure} -> {:error, Outcome.from_reason(failure)}
    end
  end

  defp run_container(config, allocation, installation, bundle) do
    arguments =
      [
        "run",
        "--name",
        Names.container(allocation.biot_id),
        "--detach",
        "--read-only",
        "--tmpfs",
        "/tmp:rw,noexec,nosuid,nodev",
        "--tmpfs",
        "/run:rw,noexec,nosuid,nodev",
        "--network",
        Names.network(allocation.network_id),
        "--uidmap",
        uid_map(config, allocation),
        "--gidmap",
        uid_map(config, allocation)
      ] ++
        Names.label_arguments(allocation.biot_id, installation.environment_id) ++
        runtime_log_arguments(config) ++
        volume_arguments(config, allocation.biot_id) ++
        [
          # The last two arguments are the container's root filesystem and the program in it that
          # runs. The bundle names both by their logical store path, which only the container sees,
          # so the root filesystem is given as the host directory holding it.
          "--rootfs",
          PrivateStore.host_path(config, allocation.biot_id, bundle.rootfs),
          StorePath.to_string(bundle.entrypoint)
        ]

    case Podman.run(config, arguments) do
      {:ok, %Command.Result{status: 0}} ->
        {:ok, :started}

      {:ok, %Command.Result{} = result} ->
        recover_create(config, allocation, installation, result)

      {:error, reason} ->
        {:error, Outcome.from_reason(reason)}
    end
  end

  # A failed create may still have made the container, and the stable name is how to tell.
  defp recover_create(config, allocation, installation, result) do
    case state(config, allocation.biot_id) do
      {:present, container} ->
        verify_started(container, allocation, installation)

      :absent ->
        {:error, Outcome.from_command(:host_unavailable, result)}

      {:unknown, failure} ->
        {:error, Outcome.from_reason(failure, HostDiagnostic.from_command(result))}
    end
  end

  defp verify_started(
         %{biot_id: biot_id, environment_id: environment_id},
         %Allocation{biot_id: biot_id},
         %Installation{environment_id: environment_id}
       ),
       do: {:ok, :started}

  defp verify_started(%{biot_id: owner}, %Allocation{biot_id: expected}, _installation)
       when owner != expected,
       do: {:error, Outcome.new(:ownership_mismatch)}

  defp verify_started(_container, _allocation, _installation), do: {:ok, :stale}

  defp remove(config, incarnation_id) do
    case Podman.run(config, ["rm", "--force", IncarnationId.to_string(incarnation_id)]) do
      {:ok, %Command.Result{status: 0}} ->
        :ok

      {:ok, %Command.Result{} = result} ->
        {:error, Outcome.from_command(:host_unavailable, result)}

      {:error, reason} ->
        {:error, Outcome.from_reason(reason)}
    end
  end

  defp ensure_network(config, allocation) do
    case Network.ensure(config, allocation.network_id) do
      :ok -> {:ok, :network}
      {:error, %Outcome{} = outcome} -> {:error, outcome}
    end
  end

  defp uid_map(config, allocation) do
    first_subordinate_id = Allocation.subordinate_start(allocation, config.uid_range_base)
    "0:#{first_subordinate_id}:#{allocation.uid_range.count}"
  end

  defp volume_arguments(config, biot_id) do
    Enum.flat_map(Paths.runtime_mounts(config, biot_id), fn {source, target, mode} ->
      ["--volume", "#{source}:#{target}:#{mode},z"]
    end)
  end

  defp runtime_log_arguments(config) do
    # The follower needs a file driver, and this bound keeps Podman's private copy from growing.
    [
      "--log-driver",
      "k8s-file",
      "--log-opt",
      "max-size=#{config.runtime_log_max_bytes}"
    ]
  end

  defp unknown_from(result) do
    unknown({:podman, result.status}, HostDiagnostic.from_command(result))
  end

  defp unreachable(reason) do
    unknown(reason, Diagnostic.text("Podman could not inspect the container"))
  end

  defp unknown(reason, detail) do
    {:unknown, Outcome.inspection(:container, reason, detail)}
  end
end
