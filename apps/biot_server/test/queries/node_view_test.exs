defmodule Biot.Server.Queries.NodeViewTest do
  use ExUnit.Case, async: true

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.NodeId
  alias Biot.Protocol.OrphanedAllocation
  alias Biot.Protocol.Platform
  alias Biot.Server.Queries.NodeView
  alias Biot.Server.Queries.NodeView.Input
  alias Biot.Server.Schema.Node
  alias Biot.Server.Schema.NodeObservation
  alias Biot.Server.TestFixtures

  setup do
    {:ok, platform} = Platform.parse("aarch64-linux")

    node = %Node{
      id: TestFixtures.id(NodeId, 1),
      status: :enabled,
      platform: platform,
      max_biots: 10
    }

    %{node: node, platform: platform, connection_id: TestFixtures.connection_id(1)}
  end

  test "the projection copies durable node facts and the capacity count", context do
    view = NodeView.project(input(context, %{assigned_biots: 4}))

    assert view.id == context.node.id
    assert view.status == :enabled
    assert view.platform == context.platform
    assert view.max_biots == 10
    assert view.assigned_biots == 4
  end

  test "every operator status is shown as it stands", context do
    for status <- [:enabled, :disabled, :retired, :abandoned] do
      view = NodeView.project(input(context, %{node: %{context.node | status: status}}))

      assert view.status == status
    end
  end

  test "the connection follows both live states and its absence", context do
    cases = [
      {%{connection_id: context.connection_id, state: :synchronizing}, :connecting},
      {%{connection_id: context.connection_id, state: :ready}, :ready},
      {nil, :unavailable}
    ]

    for {connection, expected} <- cases do
      view = NodeView.project(input(context, %{connection: connection}))

      assert view.connection == expected, "#{inspect(connection)}"
    end
  end

  test "a node that never reported has no orphan report", context do
    assert NodeView.project(input(context, %{observation: nil})).orphans == :never_reported
  end

  test "the latest orphan report appears with its time", context do
    allocation = %OrphanedAllocation{
      biot_id: TestFixtures.id(BiotId, 1),
      uid_range: %{start: 100_000, count: 65_536}
    }

    observation = %NodeObservation{
      node_id: context.node.id,
      connection_id: context.connection_id,
      received_at: ~U[2026-09-08 12:00:00.000000Z],
      orphaned_allocations: [allocation]
    }

    view = NodeView.project(input(context, %{observation: observation}))

    assert view.orphans == %{
             reported_at: ~U[2026-09-08 12:00:00.000000Z],
             allocations: [allocation]
           }
  end

  defp input(context, overrides) do
    defaults = %{
      node: context.node,
      assigned_biots: 0,
      connection: nil,
      observation: nil
    }

    struct!(Input, Map.merge(defaults, overrides))
  end
end
