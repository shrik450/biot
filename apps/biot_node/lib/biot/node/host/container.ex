defmodule Biot.Node.Host.Container do
  @moduledoc "Runs and inspects rootless Podman containers owned by one allocation."

  alias Biot.Node.Allocation
  alias Biot.Node.Diagnostic
  alias Biot.Node.Host.Command
  alias Biot.Node.Host.Config
  alias Biot.Node.Host.ContainerInspection
  alias Biot.Node.Host.Context
  alias Biot.Node.Host.Diagnostic, as: HostDiagnostic
  alias Biot.Node.Host.Environment
  alias Biot.Node.Host.FileSystem
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
    case FileSystem.read(Paths.container_identity(config, biot_id)) do
      {:present, value} ->
        state_for_identity(config, String.trim(value))

      :absent ->
        state_for_owner(config, biot_id)

      {:error, reason} ->
        unknown(reason, Diagnostic.text("the container identity could not be read"))
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
         {:ok, incarnation_id} <- start_identity(config, biot_id),
         {:ok, _container} <- create(config, allocation, installation, bundle, incarnation_id),
         do: :ok
  end

  @spec retire(Context.t(), IncarnationId.t()) :: :ok | {:error, Outcome.t()}
  def retire(%Context{biot_id: biot_id, config: config}, incarnation_id) do
    case state_for_name(config, incarnation_id) do
      :absent -> remove_identity(config, biot_id, incarnation_id)
      {:present, container} -> retire_present(config, biot_id, incarnation_id, container)
      {:unknown, failure} -> {:error, Outcome.from_reason(failure)}
    end
  end

  defp state_for_identity(config, value) do
    case IncarnationId.parse(value) do
      {:ok, incarnation_id} ->
        state_for_name(config, incarnation_id)

      {:error, _reason} ->
        unknown(:unreadable, Diagnostic.text("the container identity is invalid"))
    end
  end

  # The role filter matters: a build worker carries the same owner label, and it is not a runtime.
  defp state_for_owner(config, biot_id) do
    arguments = [
      "ps",
      "--all",
      "--filter",
      Names.owner_filter(biot_id),
      "--filter",
      Names.role_filter(:runtime),
      "--format",
      "json"
    ]

    case Podman.run(config, arguments) do
      {:ok, %Command.Result{status: 0, stdout: stdout}} ->
        parse_owned_list(config, stdout)

      {:ok, %Command.Result{} = result} ->
        unknown({:podman, result.status}, HostDiagnostic.from_command(result))

      {:error, reason} ->
        unknown(reason, Diagnostic.text("Podman could not list containers"))
    end
  end

  defp parse_owned_list(config, stdout) do
    case Jason.decode(stdout) do
      {:ok, []} ->
        :absent

      {:ok, values} when is_list(values) ->
        values
        |> Enum.map(&(Map.get(&1, "Id") || Map.get(&1, "ID")))
        |> Enum.filter(&is_binary/1)
        |> Enum.sort()
        |> case do
          [reference | _rest] ->
            state_for_reference(config, reference)

          [] ->
            unknown(
              :unreadable,
              Diagnostic.text("Podman returned a container without an identity")
            )
        end

      {:error, _reason} ->
        unknown(:unreadable, Diagnostic.text("Podman returned invalid container JSON"))

      {:ok, _other} ->
        unknown(:unreadable, Diagnostic.text("Podman returned invalid container JSON"))
    end
  end

  defp state_for_name(config, incarnation_id) do
    state_for_reference(config, Names.container(incarnation_id))
  end

  defp state_for_reference(config, reference) do
    case Podman.run(config, ["inspect", reference]) do
      {:ok, %Command.Result{status: 0, stdout: stdout}} ->
        parse_inspection(stdout)

      {:ok, %Command.Result{} = result} ->
        if Podman.absent?(:container, result),
          do: :absent,
          else: unknown({:podman, result.status}, HostDiagnostic.from_command(result))

      {:error, reason} ->
        unknown(reason, Diagnostic.text("Podman could not inspect the container"))
    end
  end

  defp parse_inspection(stdout) do
    with {:ok, [value]} <- Jason.decode(stdout),
         {:ok, container} <- ContainerInspection.parse(value) do
      {:present, container}
    else
      _error -> unknown(:unreadable, Diagnostic.text("Podman returned invalid container JSON"))
    end
  end

  defp create(config, allocation, installation, bundle, incarnation_id) do
    case state_for_name(config, incarnation_id) do
      :absent -> run_container(config, allocation, installation, bundle, incarnation_id)
      {:present, container} -> verify_started(container, allocation, installation, incarnation_id)
      {:unknown, failure} -> {:error, Outcome.from_reason(failure)}
    end
  end

  defp run_container(config, allocation, installation, bundle, incarnation_id) do
    arguments =
      [
        "run",
        "--name",
        Names.container(incarnation_id),
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
        Names.label_arguments(
          allocation.biot_id,
          incarnation_id,
          installation.environment_id
        ) ++
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
        recover_create(config, allocation, installation, incarnation_id, result)

      {:error, reason} ->
        {:error, Outcome.from_reason(reason)}
    end
  end

  defp recover_create(config, allocation, installation, incarnation_id, result) do
    case state_for_name(config, incarnation_id) do
      {:present, container} ->
        verify_started(container, allocation, installation, incarnation_id)

      :absent ->
        {:error, Outcome.from_command(:host_unavailable, result)}

      {:unknown, failure} ->
        {:error, Outcome.from_reason(failure, HostDiagnostic.from_command(result))}
    end
  end

  defp verify_started(
         %{
           biot_id: biot_id,
           incarnation_id: incarnation_id,
           environment_id: environment_id
         },
         %Allocation{biot_id: biot_id},
         %Installation{environment_id: environment_id},
         incarnation_id
       ),
       do: {:ok, :started}

  defp verify_started(%{biot_id: owner}, %Allocation{biot_id: expected}, _installation, _id)
       when owner != expected,
       do: {:error, Outcome.new(:ownership_mismatch)}

  defp verify_started(_container, _allocation, _installation, _incarnation_id),
    do: {:ok, :stale}

  defp retire_present(_config, biot_id, _incarnation_id, %{biot_id: owner})
       when owner != biot_id do
    {:error, Outcome.new(:ownership_mismatch)}
  end

  defp retire_present(
         config,
         biot_id,
         incarnation_id,
         %{biot_id: biot_id, incarnation_id: incarnation_id}
       ) do
    case Podman.run(config, ["rm", "--force", Names.container(incarnation_id)]) do
      {:ok, %Command.Result{status: 0}} ->
        remove_identity(config, biot_id, incarnation_id)

      {:ok, %Command.Result{} = result} ->
        {:error, Outcome.from_command(:host_unavailable, result)}

      {:error, reason} ->
        {:error, Outcome.from_reason(reason)}
    end
  end

  defp retire_present(_config, _biot_id, _incarnation_id, _container), do: :ok

  defp start_identity(config, biot_id) do
    path = Paths.container_identity(config, biot_id)

    case FileSystem.read(path) do
      {:present, value} -> parse_start_identity(value)
      :absent -> write_start_identity(path)
      {:error, reason} -> {:error, Outcome.from_reason(reason)}
    end
  end

  defp parse_start_identity(value) do
    case IncarnationId.parse(String.trim(value)) do
      {:ok, incarnation_id} ->
        {:ok, incarnation_id}

      {:error, _reason} ->
        {:error,
         Outcome.new(
           :host_unavailable,
           Diagnostic.text("the container identity is invalid")
         )}
    end
  end

  defp write_start_identity(path) do
    incarnation_id = IncarnationId.generate()

    # The file keeps the container name stable if Podman starts it before the effect task exits.
    case FileSystem.write_atomic(path, [IncarnationId.to_string(incarnation_id), "\n"]) do
      :ok -> {:ok, incarnation_id}
      {:error, reason} -> {:error, Outcome.from_reason(reason)}
    end
  end

  defp remove_identity(config, biot_id, incarnation_id) do
    path = Paths.container_identity(config, biot_id)

    case FileSystem.read(path) do
      :absent ->
        :ok

      {:present, value} ->
        if String.trim(value) == IncarnationId.to_string(incarnation_id),
          do: remove_identity_file(path),
          else: :ok

      {:error, reason} ->
        {:error, Outcome.from_reason(reason)}
    end
  end

  defp remove_identity_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, Outcome.from_reason(reason)}
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

  defp unknown(reason, detail) do
    {:unknown, Outcome.inspection(:container, reason, detail)}
  end
end
