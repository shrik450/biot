defmodule Biot.Server.Control.SynchronizationBehindTest do
  use Biot.Server.DataCase, async: false

  alias Biot.Protocol.BiotId
  alias Biot.Server.Biots
  alias Biot.Server.Biots.Accepted
  alias Biot.Server.Control.Synchronization
  alias Biot.Server.NodeConnections
  alias Biot.Server.Reports
  alias Biot.Server.TestFixtures

  setup do
    owner = TestFixtures.principal(1)
    node = TestFixtures.node(1)
    actor = TestFixtures.actor(owner)
    biot_id = TestFixtures.id(BiotId, 9_001)

    on_exit(fn -> NodeConnections.delete(node.id) end)

    {:ok, %Accepted{revision: 1}} =
      Biots.create(actor, biot_id, TestFixtures.create_command(name: "swept", node_id: node.id))

    %{
      actor: actor,
      node: node,
      biot_id: biot_id,
      connection_id: TestFixtures.connection_id(1),
      other_connection_id: TestFixtures.connection_id(2)
    }
  end

  test "a biot with no observation is behind", context do
    assert Synchronization.behind(context.node.id, context.connection_id) == [context.biot_id]
  end

  test "an observation from another connection leaves the biot behind", context do
    store(context, context.other_connection_id, accepted_revision: 1)

    assert Synchronization.behind(context.node.id, context.connection_id) == [context.biot_id]
  end

  test "an accepted revision below the desired revision leaves the biot behind", context do
    assert {:ok, %Accepted{revision: 2}} = Biots.stop(context.actor, context.biot_id, 1)
    store(context, context.connection_id, accepted_revision: 1)

    assert Synchronization.behind(context.node.id, context.connection_id) == [context.biot_id]
  end

  test "an accepted revision equal to the desired revision clears the biot", context do
    store(context, context.connection_id, accepted_revision: 1)

    assert Synchronization.behind(context.node.id, context.connection_id) == []
  end

  test "a later desired revision makes an accepted biot behind again", context do
    store(context, context.connection_id, accepted_revision: 1)
    assert Synchronization.behind(context.node.id, context.connection_id) == []

    assert {:ok, %Accepted{revision: 2}} = Biots.stop(context.actor, context.biot_id, 1)

    assert Synchronization.behind(context.node.id, context.connection_id) == [context.biot_id]
  end

  test "a destroyed biot stays behind until the node reports no allocation", context do
    assert {:ok, %Accepted{revision: 2}} = Biots.destroy(context.actor, context.biot_id)

    assert Synchronization.behind(context.node.id, context.connection_id) == [context.biot_id]

    store(context, context.other_connection_id,
      accepted_revision: 2,
      container: :absent,
      data: :present
    )

    assert Synchronization.behind(context.node.id, context.connection_id) == [context.biot_id]

    store(context, context.other_connection_id,
      accepted_revision: 2,
      container: :absent,
      data: :no_allocation
    )

    assert Synchronization.behind(context.node.id, context.connection_id) == []
  end

  test "only biots on this node are reported", context do
    other_node = TestFixtures.node(2)
    other_biot_id = TestFixtures.id(BiotId, 9_002)

    assert {:ok, %Accepted{}} =
             Biots.create(
               context.actor,
               other_biot_id,
               TestFixtures.create_command(name: "elsewhere", node_id: other_node.id)
             )

    assert Synchronization.behind(context.node.id, context.connection_id) == [context.biot_id]

    assert Synchronization.behind(other_node.id, context.connection_id) == [other_biot_id]
  end

  defp store(context, connection_id, report_options) do
    assert {:ok, :stored} =
             Reports.observation(
               context.node.id,
               connection_id,
               context.biot_id,
               TestFixtures.execution_report(report_options)
             )
  end
end
