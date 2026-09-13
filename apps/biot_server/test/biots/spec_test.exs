defmodule Biot.Server.Biots.SpecTest do
  use Biot.Server.DataCase, async: false

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.BiotSpec
  alias Biot.Server.Biots
  alias Biot.Server.Biots.Accepted
  alias Biot.Server.Biots.SelectEnvironment
  alias Biot.Server.BiotSpecs
  alias Biot.Server.NodeConnections
  alias Biot.Server.Repo
  alias Biot.Server.Schema.Biot, as: BiotRow
  alias Biot.Server.Schema.Environment
  alias Biot.Server.TestFixtures

  setup do
    owner = TestFixtures.principal(1)
    node = TestFixtures.node(1)
    actor = TestFixtures.actor(owner)
    biot_id = TestFixtures.id(BiotId, 9_001)

    on_exit(fn -> NodeConnections.delete(node.id) end)

    {:ok, %Accepted{}} =
      Biots.create(actor, biot_id, TestFixtures.create_command(name: "worker", node_id: node.id))

    %{owner: owner, actor: actor, node: node, biot_id: biot_id}
  end

  test "spec builds the node-facing intent and round-trips through its encoding", context do
    biot = Repo.get!(BiotRow, context.biot_id)
    environment = Repo.get!(Environment, biot.desired_environment_id)

    assert {:ok, %BiotSpec{} = spec} = BiotSpecs.build(context.biot_id)
    assert spec.access_revision == biot.access_revision
    assert spec.execution.biot_id == context.biot_id
    assert spec.execution.repository == biot.repository
    assert spec.execution.desired == BiotRow.desired(biot)
    assert spec.execution.environment == %{id: environment.id, selection: environment.selection}

    assert BiotSpec.parse(BiotSpec.encode(spec)) == {:ok, spec}
  end

  test "spec follows the selected environment and the access revision", context do
    command = %SelectEnvironment{selection: TestFixtures.selection()}

    assert {:ok, %Accepted{revision: 2}} =
             Biots.update_environment(context.actor, context.biot_id, command, 1)

    assert {:ok, spec} = BiotSpecs.build(context.biot_id)
    assert spec.execution.desired.revision == 2

    assert spec.execution.environment.id ==
             Repo.get!(BiotRow, context.biot_id).desired_environment_id

    assert BiotSpec.parse(BiotSpec.encode(spec)) == {:ok, spec}

    assert {:ok, %Accepted{revision: 3}} = Biots.destroy(context.actor, context.biot_id)

    assert {:ok, destroyed_spec} = BiotSpecs.build(context.biot_id)
    assert destroyed_spec.execution.desired.state == :destroyed
    assert destroyed_spec.access_revision == 2
    assert BiotSpec.parse(BiotSpec.encode(destroyed_spec)) == {:ok, destroyed_spec}
  end

  test "spec for an unknown biot is not found" do
    assert BiotSpecs.build(TestFixtures.id(BiotId, 9_999)) == {:error, :not_found}
  end
end
