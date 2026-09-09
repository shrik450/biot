defmodule Biot.Server.Policy.EnforcementTest do
  use ExUnit.Case, async: true

  alias Biot.Protocol.{BiotId, ConnectionId, NodeId}
  alias Biot.Server.Policy.Enforcement
  alias Biot.Server.Schema.{AccessObservation, Biot}

  setup_all do
    {:ok, biot_id} = BiotId.parse("10000000-0000-4000-8000-000000000001")
    {:ok, node_id} = NodeId.parse("20000000-0000-4000-8000-000000000002")
    {:ok, current} = ConnectionId.parse("30000000-0000-4000-8000-000000000003")
    {:ok, stale} = ConnectionId.parse("40000000-0000-4000-8000-000000000004")

    %{
      biot: %Biot{id: biot_id, node_id: node_id, access_revision: 2},
      current: current,
      stale: stale
    }
  end

  test "access covers nil rows, connection currency, and every revision relationship", context do
    cases = [
      {nil, nil, {:pending, context.biot.node_id}},
      {nil, connection(context.current, :ready), {:pending, context.biot.node_id}},
      {access_observation(context.current, 1), nil, {:pending, context.biot.node_id}},
      {access_observation(context.stale, 1), connection(context.current, :ready),
       {:pending, context.biot.node_id}},
      {access_observation(context.stale, 2), connection(context.current, :ready),
       {:pending, context.biot.node_id}},
      {access_observation(context.stale, 3), connection(context.current, :ready),
       {:pending, context.biot.node_id}},
      {access_observation(context.current, 1), connection(context.current, :ready),
       {:pending, context.biot.node_id}},
      {access_observation(context.current, 2), connection(context.current, :ready), :applied},
      {access_observation(context.current, 3), connection(context.current, :ready), :applied},
      {access_observation(context.current, 2), connection(context.current, :synchronizing),
       :applied}
    ]

    for {access_observation, connection, expected} <- cases do
      assert Enforcement.access(context.biot, access_observation, connection) == expected
    end
  end

  defp connection(connection_id, state), do: %{connection_id: connection_id, state: state}

  defp access_observation(connection_id, revision) do
    %AccessObservation{connection_id: connection_id, applied_access_revision: revision}
  end
end
