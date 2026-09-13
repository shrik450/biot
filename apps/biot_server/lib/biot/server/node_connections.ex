defmodule Biot.Server.NodeConnections do
  @moduledoc """
  Reads and writes each node's control connection through the unique control Registry.

  The Registry is the only node membership table. Its key is the node ID, its process is the
  control connection, and its value is that connection's ID and readiness. Only the owning control
  process writes its entry, and the entry leaves the Registry when that process exits.
  """

  alias Biot.Protocol.ConnectionId
  alias Biot.Protocol.NodeId

  @registry Biot.Server.Control.Registry

  @states [:synchronizing, :ready]
  @type state :: :synchronizing | :ready

  @type connection :: %{connection_id: ConnectionId.t(), state: state()}

  @doc "Makes the calling process the node's connection, or updates the entry it already owns."
  @spec put(NodeId.t(), connection()) :: :ok | {:error, {:already_registered, pid()}}
  def put(%NodeId{} = node_id, %{connection_id: %ConnectionId{}, state: state} = connection)
      when state in @states do
    case Registry.register(@registry, node_id, connection) do
      {:ok, _owner} ->
        :ok

      {:error, {:already_registered, owner}} when owner == self() ->
        {_new, _old} = Registry.update_value(@registry, node_id, fn _old -> connection end)
        :ok

      {:error, {:already_registered, _owner}} = taken ->
        taken
    end
  end

  @doc "Removes the node's entry if the calling process owns it."
  @spec delete(NodeId.t()) :: :ok
  def delete(%NodeId{} = node_id), do: Registry.unregister(@registry, node_id)

  @spec current(NodeId.t()) :: connection() | nil
  def current(%NodeId{} = node_id) do
    case live_entry(node_id) do
      {_pid, connection} -> connection
      nil -> nil
    end
  end

  @doc "Returns the process that owns the node's connection in any state."
  @spec connection_pid(NodeId.t()) :: pid() | nil
  def connection_pid(%NodeId{} = node_id) do
    case live_entry(node_id) do
      {pid, _connection} -> pid
      nil -> nil
    end
  end

  @doc "Returns the process that owns the node's current ready connection."
  @spec ready(NodeId.t()) :: {:ok, pid()} | {:error, :temporarily_unavailable}
  def ready(%NodeId{} = node_id) do
    case ready_connection(node_id) do
      {:ok, pid, _connection_id} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the current ready connection's process and its connection id together."
  @spec ready_connection(NodeId.t()) ::
          {:ok, pid(), ConnectionId.t()} | {:error, :temporarily_unavailable}
  def ready_connection(%NodeId{} = node_id) do
    case live_entry(node_id) do
      {pid, %{connection_id: connection_id, state: :ready}} -> {:ok, pid, connection_id}
      _not_ready -> {:error, :temporarily_unavailable}
    end
  end

  @spec current?(ConnectionId.t() | nil, connection() | nil) :: boolean()
  def current?(%ConnectionId{} = id, %{connection_id: %ConnectionId{} = id}), do: true
  def current?(_connection_id, _connection), do: false

  # The Registry removes a killed owner's entry only after it handles the exit signal, so a lookup
  # can still return that owner for a moment.
  defp live_entry(node_id) do
    case Registry.lookup(@registry, node_id) do
      [{pid, connection}] -> if Process.alive?(pid), do: {pid, connection}
      [] -> nil
    end
  end
end
