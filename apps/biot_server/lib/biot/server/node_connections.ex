defmodule Biot.Server.NodeConnections do
  @moduledoc "Tracks the current live connection and synchronization state for each node."

  use GenServer

  alias Biot.Protocol.ConnectionId
  alias Biot.Protocol.NodeId

  @states [:synchronizing, :ready]
  @type state :: :synchronizing | :ready

  @type connection :: %{connection_id: ConnectionId.t(), state: state()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec put(NodeId.t(), connection()) :: :ok
  def put(%NodeId{} = node_id, %{connection_id: %ConnectionId{}, state: state} = connection)
      when state in @states do
    GenServer.call(__MODULE__, {:put, node_id, connection})
  end

  @spec delete(NodeId.t()) :: :ok
  def delete(%NodeId{} = node_id), do: GenServer.call(__MODULE__, {:delete, node_id})

  @spec delete(NodeId.t(), ConnectionId.t()) :: :ok
  def delete(%NodeId{} = node_id, %ConnectionId{} = connection_id) do
    GenServer.call(__MODULE__, {:delete, node_id, connection_id})
  end

  @spec current(NodeId.t()) :: connection() | nil
  def current(%NodeId{} = node_id) do
    case :ets.lookup(__MODULE__, node_id) do
      [{^node_id, connection}] -> connection
      [] -> nil
    end
  end

  @impl true
  def init(:ok) do
    __MODULE__ = :ets.new(__MODULE__, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, :no_state}
  end

  @impl true
  def handle_call({:put, node_id, connection}, _from, state) do
    true = :ets.insert(__MODULE__, {node_id, connection})
    {:reply, :ok, state}
  end

  def handle_call({:delete, node_id}, _from, state) do
    true = :ets.delete(__MODULE__, node_id)
    {:reply, :ok, state}
  end

  def handle_call({:delete, node_id, connection_id}, _from, state) do
    case :ets.lookup(__MODULE__, node_id) do
      [{^node_id, %{connection_id: ^connection_id}}] -> :ets.delete(__MODULE__, node_id)
      _other -> :ok
    end

    {:reply, :ok, state}
  end
end
