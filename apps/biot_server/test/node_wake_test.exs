defmodule Biot.Server.NodeWakeTest do
  use Biot.Server.DataCase, async: false

  alias Biot.Protocol.BiotId
  alias Biot.Server.Biots
  alias Biot.Server.Biots.Accepted
  alias Biot.Server.Biots.SelectEnvironment
  alias Biot.Server.Biots.Unchanged
  alias Biot.Server.NodeWake
  alias Biot.Server.TestFixtures

  setup do
    owner = TestFixtures.principal(1)
    node = TestFixtures.node(1)
    other_node = TestFixtures.node(2)
    actor = TestFixtures.actor(owner)

    :ok = NodeWake.subscribe(node.id)

    %{
      actor: actor,
      stranger: TestFixtures.actor(TestFixtures.principal(2)),
      node: node,
      other_node: other_node,
      biot_id: TestFixtures.id(BiotId, 9_001)
    }
  end

  test "creation wakes the assigned node", context do
    command = TestFixtures.create_command(node_id: context.node.id)

    assert {:ok, %Accepted{}} = Biots.create(context.actor, context.biot_id, command)
    assert_receive {:biot_spec_changed, biot_id}
    assert biot_id == context.biot_id
  end

  test "every committed lifecycle change wakes the assigned node", context do
    command = TestFixtures.create_command(node_id: context.node.id)
    assert {:ok, %Accepted{}} = Biots.create(context.actor, context.biot_id, command)
    assert_receive {:biot_spec_changed, _created}

    changes = [
      fn -> Biots.stop(context.actor, context.biot_id, 1) end,
      fn -> Biots.start(context.actor, context.biot_id, 2) end,
      fn ->
        Biots.update_environment(
          context.actor,
          context.biot_id,
          %SelectEnvironment{selection: TestFixtures.selection()},
          3
        )
      end,
      fn -> Biots.destroy(context.actor, context.biot_id) end
    ]

    for change <- changes do
      assert {:ok, %Accepted{}} = change.()
      assert_receive {:biot_spec_changed, woken}
      assert woken == context.biot_id
    end
  end

  test "a request that changes nothing wakes nobody", context do
    command = TestFixtures.create_command(node_id: context.node.id)
    assert {:ok, %Accepted{}} = Biots.create(context.actor, context.biot_id, command)
    assert_receive {:biot_spec_changed, _created}

    assert {:ok, %Unchanged{}} = Biots.start(context.actor, context.biot_id, 1)
    assert {:ok, %Accepted{}} = Biots.create(context.actor, context.biot_id, command)

    refute_receive {:biot_spec_changed, _biot_id}
  end

  test "a rejected request wakes nobody", context do
    command = TestFixtures.create_command(node_id: context.node.id)
    assert {:ok, %Accepted{}} = Biots.create(context.actor, context.biot_id, command)
    assert_receive {:biot_spec_changed, _created}

    assert Biots.stop(context.actor, context.biot_id, 7) == {:error, {:revision_conflict, 1}}
    assert Biots.stop(context.stranger, context.biot_id, 1) == {:error, :forbidden}
    assert Biots.destroy(nil, context.biot_id) == {:error, :unauthenticated}

    refute_receive {:biot_spec_changed, _biot_id}
  end

  test "a change on another node stays off this node's topic", context do
    command = TestFixtures.create_command(node_id: context.other_node.id)

    assert {:ok, %Accepted{}} = Biots.create(context.actor, context.biot_id, command)

    refute_receive {:biot_spec_changed, _biot_id}
  end
end
