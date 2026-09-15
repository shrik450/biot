defmodule Biot.Server.Queries.NodesTest do
  use Biot.Server.DataCase, async: false

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.Platform
  alias Biot.Server.Biots
  alias Biot.Server.Biots.Accepted
  alias Biot.Server.NodeConnections
  alias Biot.Server.Queries
  alias Biot.Server.Reports
  alias Biot.Server.Schema.NodeObservation
  alias Biot.Server.TestFixtures

  setup do
    owner = TestFixtures.principal(1)
    stranger = TestFixtures.principal(2)
    first = TestFixtures.node(1, max_biots: 4)
    second = TestFixtures.node(2, max_biots: 7)

    on_exit(fn ->
      NodeConnections.delete(first.id)
      NodeConnections.delete(second.id)
    end)

    %{
      actor: TestFixtures.actor(owner),
      stranger_actor: TestFixtures.actor(stranger),
      first: first,
      second: second,
      connection_id: TestFixtures.connection_id(1)
    }
  end

  test "any authenticated actor sees every node in id order", context do
    for actor <- [context.actor, context.stranger_actor] do
      assert {:ok, views} = Queries.Nodes.list(actor)
      assert Enum.map(views, & &1.id) == [context.first.id, context.second.id]
      assert Enum.map(views, & &1.max_biots) == [4, 7]
      assert Enum.map(views, & &1.assigned_biots) == [0, 0]
      assert Enum.map(views, & &1.connection) == [:unavailable, :unavailable]
      assert Enum.map(views, & &1.orphans) == [:never_reported, :never_reported]
    end

    assert Queries.Nodes.list(nil) == {:error, :unauthenticated}
  end

  test "assigned biots count only the biots still holding capacity", context do
    create(context, context.first, 1, "live")
    released = create(context, context.first, 2, "released")
    held = create(context, context.first, 3, "held")
    create(context, context.second, 4, "elsewhere")

    assert counts(context) == %{context.first.id => 3, context.second.id => 1}

    assert {:ok, %Accepted{revision: 2}} = Biots.destroy(context.actor, released)
    assert {:ok, %Accepted{revision: 2}} = Biots.destroy(context.actor, held)

    assert counts(context) == %{context.first.id => 3, context.second.id => 1}

    report(context, held, :present)
    assert counts(context) == %{context.first.id => 3, context.second.id => 1}

    report(context, released, :no_allocation)
    assert counts(context) == %{context.first.id => 2, context.second.id => 1}

    assert {:ok, view} = node_view(context, context.first.id)
    assert view.assigned_biots == 2
  end

  test "the connection comes from the live registry", context do
    NodeConnections.put(context.first.id, %{
      connection_id: context.connection_id,
      state: :synchronizing
    })

    assert {:ok, view} = node_view(context, context.first.id)
    assert view.connection == :connecting

    NodeConnections.put(context.first.id, %{
      connection_id: context.connection_id,
      state: :ready
    })

    assert {:ok, view} = node_view(context, context.first.id)
    assert view.connection == :ready

    NodeConnections.delete(context.first.id)

    assert {:ok, view} = node_view(context, context.first.id)
    assert view.connection == :unavailable
  end

  test "orphans come from the latest node observation", context do
    allocation = TestFixtures.orphaned_allocation(1)

    :ok =
      NodeConnections.put(context.first.id, %{connection_id: context.connection_id, state: :ready})

    assert {:ok, %NodeObservation{}} =
             Reports.node_observation(context.first.id, context.connection_id, [allocation])

    assert {:ok, view} = node_view(context, context.first.id)
    assert view.orphans.allocations == [allocation]
    assert %DateTime{} = view.orphans.reported_at

    assert {:ok, second_view} = node_view(context, context.second.id)
    assert second_view.orphans == :never_reported

    assert {:ok, %NodeObservation{}} =
             Reports.node_observation(context.first.id, context.connection_id, [])

    assert {:ok, cleared} = node_view(context, context.first.id)
    assert cleared.orphans.allocations == []
  end

  test "the operator status and platform are shown as stored", context do
    disabled = TestFixtures.node(3, status: :disabled, platform: platform())

    assert {:ok, view} = node_view(context, disabled.id)
    assert view.status == :disabled
    assert view.platform == platform()
  end

  defp platform do
    {:ok, platform} = Platform.parse("aarch64-linux")
    platform
  end

  defp create(context, node, number, name) do
    biot_id = TestFixtures.id(BiotId, 9_000 + number)
    command = TestFixtures.create_command(name: name, node_id: node.id)

    assert {:ok, %Accepted{}} = Biots.create(context.actor, biot_id, command)
    biot_id
  end

  defp report(context, biot_id, data) do
    :ok =
      NodeConnections.put(context.first.id, %{
        connection_id: context.connection_id,
        state: :ready
      })

    assert {:ok, :stored} =
             Reports.observation(
               context.first.id,
               context.connection_id,
               biot_id,
               TestFixtures.execution_report(
                 accepted_revision: 2,
                 container: :absent,
                 data: data
               )
             )
  end

  defp counts(context) do
    assert {:ok, views} = Queries.Nodes.list(context.actor)
    Map.new(views, &{&1.id, &1.assigned_biots})
  end

  defp node_view(context, node_id) do
    assert {:ok, views} = Queries.Nodes.list(context.actor)
    {:ok, Enum.find(views, &(&1.id == node_id))}
  end
end
