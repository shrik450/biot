defmodule Biot.Node.RuntimeLogs do
  @moduledoc "Owns bounded service-runner capture and reads its current or most recent output."

  use Supervisor

  require Logger

  alias Biot.Node.Host.Config
  alias Biot.Node.Host.FileSystem
  alias Biot.Node.Host.Paths
  alias Biot.Node.NodeState
  alias Biot.Node.RuntimeLogs.Capture
  alias Biot.Node.RuntimeLogs.Metadata
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.IncarnationId

  @registry __MODULE__.Registry
  @captures __MODULE__.Captures

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(_options \\ []) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @captures, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc "Keeps a capture attached while inspection finds a present, non-exited container."
  @spec attach(Config.t(), BiotId.t(), NodeState.resource(NodeState.container())) :: :ok
  def attach(
        %Config{},
        %BiotId{},
        {:present, %{state: {:exited, _status}}}
      ) do
    :ok
  end

  def attach(
        %Config{} = config,
        %BiotId{} = biot_id,
        {:present, %{incarnation_id: %IncarnationId{} = incarnation_id}}
      ) do
    case ensure_capture(config, biot_id, incarnation_id) do
      :ok -> :ok
      {:error, reason} -> log_capture_failure(biot_id, incarnation_id, reason)
    end
  end

  def attach(%Config{}, %BiotId{}, :absent), do: :ok
  def attach(%Config{}, %BiotId{}, {:unknown, _failure}), do: :ok

  @doc "Stops capture and removes runtime output after a snapshot omits the Biot."
  @spec forget(BiotId.t()) :: :ok
  def forget(%BiotId{} = biot_id) do
    config = Config.current!()
    stop_capture(biot_id)
    remove_files(config, biot_id)
    :ok
  end

  @spec fetch(BiotId.t(), pos_integer()) ::
          {:ok, {IncarnationId.t(), binary(), boolean()}} | :not_found
  def fetch(%BiotId{} = biot_id, max_bytes)
      when is_integer(max_bytes) and max_bytes > 0 do
    config = Config.current!()

    with {:ok, {incarnation_id, capture_truncated}} <- Metadata.read(config, biot_id),
         {:ok, content} <- File.read(Paths.runtime_log(config, biot_id)) do
      {content, request_truncated} = tail(content, max_bytes)

      {:ok, {incarnation_id, content, capture_truncated or request_truncated}}
    else
      _missing_or_unreadable -> :not_found
    end
  end

  defp ensure_capture(config, biot_id, incarnation_id) do
    case Registry.lookup(@registry, biot_id) do
      [] -> begin(config, biot_id, incarnation_id)
      [{_pid, ^incarnation_id}] -> :ok
      [{pid, _old_incarnation_id}] -> replace_capture(pid, config, biot_id, incarnation_id)
    end
  end

  defp begin(config, biot_id, incarnation_id) do
    case Metadata.read(config, biot_id) do
      {:ok, {^incarnation_id, _truncated}} ->
        with :ok <- Metadata.write(config, biot_id, incarnation_id, true),
             do: start_capture(config, biot_id, incarnation_id, :new, true)

      _different_or_missing ->
        with :ok <- FileSystem.write_atomic(Paths.runtime_log(config, biot_id), ""),
             :ok <- Metadata.write(config, biot_id, incarnation_id, false),
             do: start_capture(config, biot_id, incarnation_id, :all, false)
    end
  end

  defp tail(content, max_bytes) when byte_size(content) > max_bytes do
    start = byte_size(content) - max_bytes
    {binary_part(content, start, max_bytes), true}
  end

  defp tail(content, _max_bytes), do: {content, false}

  defp start_capture(config, biot_id, incarnation_id, tail, truncated) do
    case DynamicSupervisor.start_child(
           @captures,
           {Capture,
            config: config,
            biot_id: biot_id,
            incarnation_id: incarnation_id,
            name: capture_name(biot_id, incarnation_id),
            tail: tail,
            truncated: truncated}
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp replace_capture(pid, config, biot_id, incarnation_id) do
    case DynamicSupervisor.terminate_child(@captures, pid) do
      :ok -> begin(config, biot_id, incarnation_id)
      {:error, :not_found} -> begin(config, biot_id, incarnation_id)
    end
  end

  defp capture_name(biot_id, incarnation_id),
    do: {:via, Registry, {@registry, biot_id, incarnation_id}}

  defp stop_capture(biot_id) do
    case Registry.lookup(@registry, biot_id) do
      [{pid, _incarnation_id}] -> DynamicSupervisor.terminate_child(@captures, pid)
      [] -> :ok
    end
  end

  defp remove_files(config, biot_id) do
    [Paths.runtime_log(config, biot_id), Paths.runtime_log_metadata(config, biot_id)]
    |> Enum.each(&remove/1)
  end

  defp remove(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> Logger.warning("could not remove runtime log file: #{inspect(reason)}")
    end
  end

  defp log_capture_failure(biot_id, incarnation_id, reason) do
    Logger.warning(
      "could not attach runtime log capture for #{BiotId.to_string(biot_id)} " <>
        "incarnation #{IncarnationId.to_string(incarnation_id)}: #{inspect(reason)}"
    )

    :ok
  end
end
