defmodule Biot.Server.NodeConnectionsTest do
  use ExUnit.Case, async: false

  alias Biot.Protocol.ConnectionId
  alias Biot.Protocol.NodeId
  alias Biot.Server.NodeConnections

  @node_uuid "b0000000-0000-4000-8000-00000000000b"
  @other_node_uuid "c0000000-0000-4000-8000-00000000000c"
  @connection_uuid "d0000000-0000-4000-8000-00000000000d"

  setup do
    {:ok, node_id} = NodeId.parse(@node_uuid)
    {:ok, other_node_id} = NodeId.parse(@other_node_uuid)
    {:ok, connection_id} = ConnectionId.parse(@connection_uuid)

    on_exit(fn ->
      NodeConnections.delete(node_id)
      NodeConnections.delete(other_node_id)
    end)

    %{node_id: node_id, other_node_id: other_node_id, connection_id: connection_id}
  end

  test "a node with no connection has none", context do
    assert NodeConnections.current(context.node_id) == nil
  end

  test "put replaces the node's current connection and delete removes it", context do
    synchronizing = %{connection_id: context.connection_id, state: :synchronizing}
    assert NodeConnections.put(context.node_id, synchronizing) == :ok
    assert NodeConnections.current(context.node_id) == synchronizing

    ready = %{connection_id: context.connection_id, state: :ready}
    assert NodeConnections.put(context.node_id, ready) == :ok
    assert NodeConnections.current(context.node_id) == ready

    assert NodeConnections.delete(context.node_id) == :ok
    assert NodeConnections.current(context.node_id) == nil
  end

  test "each node holds its own connection", context do
    first = %{connection_id: context.connection_id, state: :ready}
    assert NodeConnections.put(context.node_id, first) == :ok

    assert NodeConnections.current(context.other_node_id) == nil
    assert NodeConnections.delete(context.other_node_id) == :ok
    assert NodeConnections.current(context.node_id) == first
  end

  test "any process reads the same connection", context do
    connection = %{connection_id: context.connection_id, state: :ready}
    assert NodeConnections.put(context.node_id, connection) == :ok

    task = Task.async(fn -> NodeConnections.current(context.node_id) end)
    assert Task.await(task) == connection
  end

  test "a connection state outside the closed set is rejected", context do
    unsupported = %{connection_id: context.connection_id, state: unsupported_state()}

    assert_raise FunctionClauseError, fn ->
      NodeConnections.put(context.node_id, unsupported)
    end

    assert NodeConnections.current(context.node_id) == nil
  end

  # Built at runtime so the type checker cannot rule the call out before it runs.
  defp unsupported_state, do: String.to_atom("connected")
end
