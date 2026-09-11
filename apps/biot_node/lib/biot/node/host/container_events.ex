defmodule Biot.Node.Host.ContainerEvents do
  @moduledoc """
  Wakes the controller that owns a container when Podman reports that the container died.

  An event is a hint. Inspection decides what is true, and a settled controller inspects again on
  its observation interval, so a missed event costs time and nothing else. The reader therefore
  holds nothing worth recovering: it owns one Podman stream and reads it.

  Podman may be unavailable, and it may stop streaming at any moment. This reader answers both the
  same way: it waits and opens the stream again. Stopping instead would spend the node supervisor's
  restart budget on a hint source, and a Podman that keeps failing would take the whole node down
  with it.

  The stream runs through `Biot.Node.Host.Command`, so the reader's death ends Podman's process
  group with it. The reader outlives its streams, so it closes each one that ends before it opens
  the next: the command's process group and its stderr file belong to whoever opened it.
  """

  use GenServer

  require Logger

  alias Biot.Node.Controllers
  alias Biot.Node.Host.Command
  alias Biot.Node.Host.Config
  alias Biot.Node.Host.Names
  alias Biot.Node.Host.Podman

  # A build worker dies on every build, so the stream asks for runtimes only: an exit a controller
  # should hear about is always a runtime's.
  defp arguments do
    [
      "events",
      "--format",
      "json",
      "--filter",
      "type=container",
      "--filter",
      "event=died",
      "--filter",
      Names.role_filter(:runtime)
    ]
  end

  defmodule State do
    @moduledoc false

    @enforce_keys [:retry_ms]
    defstruct [:retry_ms, stream: nil, buffer: ""]

    @type t :: %__MODULE__{
            retry_ms: pos_integer(),
            stream: Command.Stream.t() | nil,
            buffer: binary()
          }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def init(_options) do
    retry_ms = Application.fetch_env!(:biot_node, :container_events_retry_ms)
    {:ok, %State{retry_ms: retry_ms}, {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, %State{} = state), do: {:noreply, open(state)}

  @impl true
  def handle_info(:open, %State{} = state), do: {:noreply, open(state)}

  def handle_info({port, {:data, data}}, %State{stream: %Command.Stream{port: port}} = state) do
    {:noreply, %{state | buffer: read_lines(state.buffer <> data)}}
  end

  def handle_info(
        {port, {:exit_status, status}},
        %State{stream: %Command.Stream{port: port} = stream} = state
      ) do
    :ok = Command.close(stream)
    {:noreply, reopen_later(state, {:podman_events_ended, status})}
  end

  # The stream this reader replaced can still have output and its exit status in the mailbox. Both
  # describe a stream this reader has already closed.
  def handle_info({port, {:data, _data}}, %State{} = state) when is_port(port),
    do: {:noreply, state}

  def handle_info({port, {:exit_status, _status}}, %State{} = state) when is_port(port),
    do: {:noreply, state}

  defp open(%State{} = state) do
    case opened_stream() do
      {:ok, stream} -> %{state | stream: stream, buffer: ""}
      {:error, reason} -> reopen_later(state, reason)
    end
  end

  defp opened_stream do
    case Config.from_application() do
      {:ok, config} -> Podman.open(config, arguments())
      {:error, reason} -> {:error, {:host_not_configured, reason}}
    end
  end

  defp reopen_later(%State{} = state, reason) do
    Logger.warning(
      "podman container events unavailable (#{inspect(reason)}); opening the stream again in #{state.retry_ms} ms"
    )

    Process.send_after(self(), :open, state.retry_ms)
    %{state | stream: nil, buffer: ""}
  end

  defp read_lines(buffer) do
    case String.split(buffer, "\n", parts: 2) do
      [unfinished] ->
        unfinished

      [line, rest] ->
        wake(line)
        read_lines(rest)
    end
  end

  # Every container on the host reports its death here, and only this node's containers carry a
  # biot label. A line without one, or one the node cannot read, names no controller.
  defp wake(line) do
    with {:ok, %{"Attributes" => attributes}} <- Jason.decode(line),
         {:ok, biot_id} <- Names.owner(attributes) do
      Controllers.container_exited(biot_id)
    else
      _unowned -> :ok
    end
  end
end
