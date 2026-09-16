defmodule Biot.Server.CommitEffectsTest do
  use Biot.Server.DataCase, async: false

  alias Biot.Protocol.BiotId
  alias Biot.Server.Access.Owners
  alias Biot.Server.BiotChange
  alias Biot.Server.CommitEffects
  alias Biot.Server.NodeWake
  alias Biot.Server.TestFixtures
  alias Biot.Server.Tokens

  setup do
    owner = TestFixtures.principal(1)
    node = TestFixtures.node(1)
    {biot, _environment} = TestFixtures.biot(owner, node, 1)
    :ok = NodeWake.subscribe(node.id)
    :ok = BiotChange.subscribe(biot.id)
    {_token, digest} = Tokens.mint()
    :ok = Owners.register(biot.id, owner.id, [{:control_session, digest}])

    on_exit(fn ->
      Owners.unregister()
      BiotChange.unsubscribe(biot.id)
    end)

    %{biot: biot, node: node}
  end

  test "enforce closes owners before waking nodes and notifying readers", context do
    biot_id = context.biot.id

    assert :ok =
             CommitEffects.enforce(%CommitEffects{
               owners: [{:biot, context.biot.id}],
               wakes: [{context.node.id, context.biot.id}],
               readers: [context.biot.id]
             })

    assert_receive first
    assert first == {:biot_access, :close}
    assert_receive {:biot_spec_changed, ^biot_id}
    assert_receive {:biot_changed, ^biot_id}
  end

  test "empty effects are a no-op" do
    assert :ok = CommitEffects.enforce(%CommitEffects{owners: [], wakes: [], readers: []})
    refute_receive {:biot_access, :close}
    refute_receive {:biot_spec_changed, _biot_id}
    refute_receive {:biot_changed, _biot_id}
  end

  test "BiotChange topics isolate subscribers by BiotId", context do
    biot_id = context.biot.id
    other_biot_id = TestFixtures.id(BiotId, 9_999)
    :ok = BiotChange.subscribe(other_biot_id)
    on_exit(fn -> BiotChange.unsubscribe(other_biot_id) end)

    assert :ok = BiotChange.changed(biot_id)
    assert_receive {:biot_changed, ^biot_id}
    refute_receive {:biot_changed, ^other_biot_id}
  end
end
