defmodule Biot.Node.RuntimeLogs.Capture do
  @moduledoc "Copies one container's output into its bounded node-private runtime log."

  use GenServer

  require Logger

  alias Biot.Node.Host.Command
  alias Biot.Node.Host.Names
  alias Biot.Node.Host.Paths
  alias Biot.Node.Host.Podman
  alias Biot.Node.RuntimeLogs.Metadata

  defmodule State do
    @moduledoc false

    @enforce_keys [:stream, :file, :remaining, :config, :biot_id, :incarnation_id]
    defstruct [:stream, :file, :remaining, :config, :biot_id, :incarnation_id, truncated: false]

    @type t :: %__MODULE__{
            stream: Command.Stream.t(),
            file: :file.io_device(),
            remaining: non_neg_integer(),
            config: Biot.Node.Host.Config.t(),
            biot_id: Biot.Protocol.BiotId.t(),
            incarnation_id: Biot.Protocol.IncarnationId.t(),
            truncated: boolean()
          }
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options) do
    %{
      id: {__MODULE__, Keyword.fetch!(options, :biot_id)},
      start: {__MODULE__, :start_link, [options]},
      restart: :temporary
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: Keyword.fetch!(options, :name))
  end

  @impl true
  def init(options) do
    config = Keyword.fetch!(options, :config)
    biot_id = Keyword.fetch!(options, :biot_id)
    incarnation_id = Keyword.fetch!(options, :incarnation_id)
    path = Paths.runtime_log(config, biot_id)
    tail = Keyword.fetch!(options, :tail)

    with {:ok, file} <- File.open(path, [:append, :binary]),
         {:ok, stream} <- open_stream(config, incarnation_id, tail) do
      remaining = max(config.runtime_log_max_bytes - file_size(path), 0)

      {:ok,
       %State{
         stream: stream,
         file: file,
         remaining: remaining,
         config: config,
         biot_id: biot_id,
         incarnation_id: incarnation_id,
         truncated: Keyword.fetch!(options, :truncated)
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info(
        {port, {:data, data}},
        %State{stream: %Command.Stream{port: port}} = state
      ) do
    {:noreply, write(state, data)}
  end

  def handle_info(
        {port, {:exit_status, _status}},
        %State{stream: %Command.Stream{port: port}} = state
      ) do
    :ok = Command.close(state.stream)
    {:stop, :normal, state}
  end

  def handle_info({port, _message}, %State{} = state) when is_port(port), do: {:noreply, state}

  @impl true
  def terminate(_reason, %State{file: file}) do
    File.close(file)
    :ok
  end

  defp open_stream(config, incarnation_id, :all) do
    Podman.open_combined(config, ["logs", "--follow", Names.container(incarnation_id)])
  end

  defp open_stream(config, incarnation_id, :new) do
    Podman.open_combined(config, [
      "logs",
      "--follow",
      "--tail",
      "0",
      Names.container(incarnation_id)
    ])
  end

  defp write(%State{remaining: 0} = state, <<>>), do: state
  defp write(%State{remaining: 0} = state, _data), do: mark_truncated(state)

  defp write(%State{} = state, data) do
    bytes = min(byte_size(data), state.remaining)
    :ok = IO.binwrite(state.file, binary_part(data, 0, bytes))
    state = %{state | remaining: state.remaining - bytes}
    if bytes == byte_size(data), do: state, else: mark_truncated(state)
  end

  defp mark_truncated(%State{truncated: true} = state), do: state

  defp mark_truncated(%State{} = state) do
    case Metadata.mark_truncated(state.config, state.biot_id, state.incarnation_id) do
      :ok ->
        %{state | truncated: true}

      {:error, reason} ->
        Logger.warning("could not mark runtime log as truncated: #{inspect(reason)}")
        state
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      {:error, _reason} -> 0
    end
  end
end
