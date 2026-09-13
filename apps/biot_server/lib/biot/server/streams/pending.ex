defmodule Biot.Server.Streams.Pending do
  @moduledoc """
  Owns the stream opens that have been sent to a node but not yet attached.

  One entry is registered by `open/4`, claimed by an attaching control connection, or removed by a
  failure or the open deadline. Claim and removal both happen in this one process, so exactly one
  of `attach/5` and `abandon/1` wins. A caller learns which it was from the reply and from the
  message the winning operation already put in its mailbox.

  Each entry watches the control process it captured, so control loss before a claim does not
  depend on that process running its shutdown callbacks.
  """

  use GenServer

  alias Biot.Protocol.ConnectionId
  alias Biot.Protocol.NodeId
  alias Biot.Protocol.StreamFailure
  alias Biot.Protocol.StreamId
  alias Biot.Server.NodeConnections

  defmodule Entry do
    @moduledoc false
    @enforce_keys [
      :node_id,
      :connection_id,
      :connection_pid,
      :kind,
      :caller,
      :monitor,
      :connection_monitor
    ]
    defstruct @enforce_keys
  end

  defmodule State do
    @moduledoc false
    defstruct entries: %{}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  @spec register(StreamId.t(), NodeId.t(), ConnectionId.t(), pid(), :port | :shell, pid()) :: :ok
  def register(
        %StreamId{} = id,
        %NodeId{} = node_id,
        %ConnectionId{} = connection_id,
        connection_pid,
        kind,
        caller
      ) do
    GenServer.call(
      __MODULE__,
      {:register, id, node_id, connection_id, connection_pid, kind, caller}
    )
  end

  @spec attach(NodeId.t(), ConnectionId.t(), StreamId.t(), pid(), :ssl.sslsocket()) ::
          {:ok, pid(), :port | :shell} | {:error, :unknown_stream}
  def attach(
        %NodeId{} = node_id,
        %ConnectionId{} = connection_id,
        %StreamId{} = stream_id,
        handler,
        socket
      ) do
    GenServer.call(__MODULE__, {:attach, node_id, connection_id, stream_id, handler, socket})
  end

  @spec stream_failed(StreamId.t(), StreamFailure.t()) :: :ok
  def stream_failed(%StreamId{} = stream_id, reason) do
    GenServer.call(__MODULE__, {:stream_failed, stream_id, reason})
  end

  @spec control_lost(ConnectionId.t()) :: :ok
  def control_lost(%ConnectionId{} = connection_id) do
    GenServer.call(__MODULE__, {:control_lost, connection_id})
  end

  @doc "Removes one entry. `:gone` means claim or failure already removed it."
  @spec abandon(StreamId.t()) :: :abandoned | :gone
  def abandon(%StreamId{} = stream_id) do
    GenServer.call(__MODULE__, {:abandon, stream_id})
  end

  @impl true
  def init(_options), do: {:ok, %State{}}

  @impl true
  def handle_call(
        {:register, id, node_id, connection_id, connection_pid, kind, caller},
        _from,
        state
      ) do
    entry = %Entry{
      node_id: node_id,
      connection_id: connection_id,
      connection_pid: connection_pid,
      kind: kind,
      caller: caller,
      monitor: Process.monitor(caller),
      connection_monitor: Process.monitor(connection_pid)
    }

    {:reply, :ok, %{state | entries: Map.put(state.entries, id, entry)}}
  end

  def handle_call({:attach, node_id, connection_id, stream_id, handler, socket}, _from, state) do
    case Map.fetch(state.entries, stream_id) do
      {:ok, entry} ->
        if current?(entry, node_id, connection_id) do
          Process.demonitor(entry.monitor, [:flush])
          Process.demonitor(entry.connection_monitor, [:flush])
          send(entry.caller, {:stream_claimed, stream_id, handler, socket})

          {:reply, {:ok, entry.caller, entry.kind},
           %{state | entries: Map.delete(state.entries, stream_id)}}
        else
          {:reply, {:error, :unknown_stream}, state}
        end

      :error ->
        {:reply, {:error, :unknown_stream}, state}
    end
  end

  def handle_call({:stream_failed, stream_id, reason}, _from, state) do
    case Map.pop(state.entries, stream_id) do
      {nil, _entries} ->
        {:reply, :ok, state}

      {entry, entries} ->
        Process.demonitor(entry.monitor, [:flush])
        Process.demonitor(entry.connection_monitor, [:flush])
        send(entry.caller, {:stream_failed, stream_id, reason})
        {:reply, :ok, %{state | entries: entries}}
    end
  end

  def handle_call({:control_lost, connection_id}, _from, state) do
    {lost, kept} =
      Enum.split_with(state.entries, fn {_id, entry} -> entry.connection_id == connection_id end)

    Enum.each(lost, fn {id, entry} ->
      Process.demonitor(entry.monitor, [:flush])
      Process.demonitor(entry.connection_monitor, [:flush])
      send(entry.caller, {:stream_failed, id, :node_unavailable})
    end)

    {:reply, :ok, %{state | entries: Map.new(kept)}}
  end

  def handle_call({:abandon, stream_id}, _from, state) do
    case Map.pop(state.entries, stream_id) do
      {nil, _entries} ->
        {:reply, :gone, state}

      {entry, entries} ->
        Process.demonitor(entry.monitor, [:flush])
        Process.demonitor(entry.connection_monitor, [:flush])
        {:reply, :abandoned, %{state | entries: entries}}
    end
  end

  @impl true
  def handle_info({:DOWN, reference, :process, pid, _reason}, state) do
    if connection_down?(state, reference) do
      {:noreply, fail_connection(state, pid)}
    else
      {:noreply, drop_waiter(state, reference)}
    end
  end

  defp connection_down?(state, reference) do
    Enum.any?(state.entries, fn {_id, entry} -> entry.connection_monitor == reference end)
  end

  defp drop_waiter(state, reference) do
    case Enum.find(state.entries, fn {_id, entry} -> entry.monitor == reference end) do
      nil ->
        state

      {id, entry} ->
        Process.demonitor(entry.connection_monitor, [:flush])
        %{state | entries: Map.delete(state.entries, id)}
    end
  end

  # A killed control process never runs its shutdown callbacks, so its monitor is the one path that
  # fails every open it admitted.
  defp fail_connection(state, connection_pid) do
    {lost, kept} =
      Enum.split_with(state.entries, fn {_id, entry} ->
        entry.connection_pid == connection_pid
      end)

    Enum.each(lost, fn {id, entry} ->
      Process.demonitor(entry.monitor, [:flush])
      Process.demonitor(entry.connection_monitor, [:flush])
      send(entry.caller, {:stream_failed, id, :node_unavailable})
    end)

    %{state | entries: Map.new(kept)}
  end

  defp current?(entry, node_id, connection_id) do
    entry.node_id == node_id and entry.connection_id == connection_id and
      Process.alive?(entry.connection_pid) and
      NodeConnections.current?(connection_id, NodeConnections.current(node_id))
  end
end
