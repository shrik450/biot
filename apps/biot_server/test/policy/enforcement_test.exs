defmodule Biot.Server.Policy.EnforcementTest do
  use ExUnit.Case, async: true

  alias Biot.Protocol.{BiotId, ConnectionId, NodeId}
  alias Biot.Server.Policy.Enforcement
  alias Biot.Server.Schema.{Biot, Observation}

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

  test "freshness covers every observation and connection relationship", context do
    observation = %Observation{connection_id: context.current}
    stale_observation = %Observation{connection_id: context.stale}

    cases = [
      {nil, nil, :stale},
      {observation, nil, :stale},
      {nil, connection(context.current, :ready), :stale},
      {observation, connection(context.current, :ready), :current},
      {observation, connection(context.current, :synchronizing), :current},
      {stale_observation, connection(context.current, :ready), :stale}
    ]

    for {reported, live, expected} <- cases do
      assert Enforcement.freshness(reported, live) == expected
    end
  end

  test "access covers every freshness and revision relationship", context do
    cases = [
      {nil, :stale, {:pending, context.biot.node_id}},
      {nil, :current, {:pending, context.biot.node_id}},
      {observation(1), :stale, {:pending, context.biot.node_id}},
      {observation(2), :stale, {:pending, context.biot.node_id}},
      {observation(3), :stale, {:pending, context.biot.node_id}},
      {observation(1), :current, {:pending, context.biot.node_id}},
      {observation(2), :current, :applied},
      {observation(3), :current, :applied}
    ]

    for {reported, freshness, expected} <- cases do
      assert Enforcement.access(context.biot, reported, freshness) == expected
    end
  end

  defp connection(connection_id, state), do: %{connection_id: connection_id, state: state}
  defp observation(revision), do: %Observation{applied_access_revision: revision}
end
