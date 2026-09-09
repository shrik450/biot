defmodule Biot.Server.Biots.CapacityTest do
  use Biot.Server.DataCase, async: false

  alias Biot.Protocol.BiotId
  alias Biot.Server.Biots
  alias Biot.Server.Biots.Accepted
  alias Biot.Server.Biots.Capacity
  alias Biot.Server.Repo
  alias Biot.Server.Reports
  alias Biot.Server.Schema.Node
  alias Biot.Server.TestFixtures

  setup do
    owner = TestFixtures.principal(1)

    %{
      actor: TestFixtures.actor(owner),
      node: TestFixtures.node(1, max_biots: 2),
      connection_id: TestFixtures.connection_id(1)
    }
  end

  test "a node has room below its limit and none at its limit", context do
    assert Capacity.room?(Repo, context.node)

    create(context, 1, "first")
    assert Capacity.room?(Repo, context.node)

    create(context, 2, "second")
    refute Capacity.room?(Repo, context.node)
  end

  test "a destroyed biot keeps holding its place until the node releases it", context do
    first = create(context, 1, "first")
    create(context, 2, "second")
    refute Capacity.room?(Repo, context.node)

    assert {:ok, %Accepted{revision: 2}} = Biots.destroy(context.actor, first)
    refute Capacity.room?(Repo, context.node)

    report(context, first, :present)
    refute Capacity.room?(Repo, context.node)

    report(context, first, :no_allocation)
    assert Capacity.room?(Repo, context.node)
  end

  test "biots on another node do not fill this node", context do
    other = TestFixtures.node(2, max_biots: 2)
    create(context, 1, "first")
    create(context, 2, "second")

    refute Capacity.room?(Repo, context.node)
    assert Capacity.room?(Repo, other)
  end

  test "a raised limit gives an already full node room again", context do
    create(context, 1, "first")
    create(context, 2, "second")
    refute Capacity.room?(Repo, context.node)

    raised =
      Repo.get!(Node, context.node.id)
      |> Ecto.Changeset.change(max_biots: 3)
      |> Repo.update!()

    assert Capacity.room?(Repo, raised)
  end

  test "counts reports zero for a node with no biots and skips unknown nodes", context do
    other = TestFixtures.node(2)
    create(context, 1, "first")

    counts = Capacity.counts(Repo, [context.node.id, other.id])

    assert Map.fetch!(counts, context.node.id) == 1
    refute Map.has_key?(counts, other.id)
    assert Capacity.counts(Repo, []) == %{}
  end

  defp create(context, number, name) do
    biot_id = TestFixtures.id(BiotId, 9_000 + number)
    command = TestFixtures.create_command(name: name, node_id: context.node.id)

    assert {:ok, %Accepted{}} = Biots.create(context.actor, biot_id, command)
    biot_id
  end

  defp report(context, biot_id, data) do
    assert {:ok, :stored} =
             Reports.observation(
               context.node.id,
               context.connection_id,
               biot_id,
               TestFixtures.execution_report(
                 accepted_revision: 2,
                 container: :absent,
                 data: data,
                 applied_access_revision: 2
               )
             )
  end
end
