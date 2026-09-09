defmodule Biot.Server.NodesTest do
  use Biot.Server.DataCase, async: false

  import Ecto.Query

  alias Biot.Server.Nodes
  alias Biot.Server.Repo
  alias Biot.Server.Schema.Biot, as: BiotSchema
  alias Biot.Server.Schema.Node
  alias Biot.Server.TestFixtures

  test "enrollment inserts, disables an omission, retires, and rejects re-enabling" do
    enabled = TestFixtures.registration(1)

    assert {:ok, [_node]} = Nodes.enroll([enabled])
    assert %Node{status: :enabled} = Repo.get!(Node, enabled.node_id)

    assert {:ok, [_node]} = Nodes.enroll([enabled])
    assert %Node{status: :enabled} = Repo.get!(Node, enabled.node_id)

    assert {:ok, [_node]} = Nodes.enroll([])
    assert %Node{status: :disabled} = Repo.get!(Node, enabled.node_id)

    retired = %{enabled | status: :retired}
    assert {:ok, [_node]} = Nodes.enroll([retired])
    assert %Node{status: :retired} = Repo.get!(Node, enabled.node_id)

    assert {:error, rejection} = Nodes.enroll([enabled])
    assert rejection == {:retired_cannot_enable, enabled.node_id}
    assert Nodes.message(rejection) =~ to_string(enabled.node_id)
    assert %Node{status: :retired} = Repo.get!(Node, enabled.node_id)
  end

  test "disabling increments assigned Biots and leaves other Biots unchanged" do
    first_registration = TestFixtures.registration(1)
    second_registration = TestFixtures.registration(2)
    assert {:ok, _nodes} = Nodes.enroll([first_registration, second_registration])

    first_node = Repo.get!(Node, first_registration.node_id)
    second_node = Repo.get!(Node, second_registration.node_id)
    owner = TestFixtures.principal(1)
    {first_biot, _environment} = TestFixtures.biot(owner, first_node, 1)
    {second_biot, _environment} = TestFixtures.biot(owner, first_node, 2)
    {other_biot, _environment} = TestFixtures.biot(owner, second_node, 3)

    disabled = %{first_registration | status: :disabled}
    assert {:ok, _nodes} = Nodes.enroll([disabled, second_registration])

    assert Repo.get!(BiotSchema, first_biot.id).access_revision == 2
    assert Repo.get!(BiotSchema, second_biot.id).access_revision == 2
    assert Repo.get!(BiotSchema, other_biot.id).access_revision == 1
  end

  test "retirement requires every assigned Biot to report no allocation" do
    registration = TestFixtures.registration(1)
    assert {:ok, _nodes} = Nodes.enroll([registration])

    node = Repo.get!(Node, registration.node_id)
    owner = TestFixtures.principal(1)
    {biot, _environment} = TestFixtures.biot(owner, node, 1)
    retired = %{registration | status: :retired, max_biots: 20}

    assert Nodes.enroll([retired]) ==
             {:error, {:retirement_blocked, registration.node_id}}

    assert %Node{status: :enabled, max_biots: 10} = Repo.get!(Node, registration.node_id)

    observation = TestFixtures.observation(biot, 1, data: :unknown)

    for data <- [:unknown, :uninitialized, :present, :lost] do
      observation
      |> Ecto.Changeset.change(data: data)
      |> Repo.update!()

      assert Nodes.enroll([retired]) ==
               {:error, {:retirement_blocked, registration.node_id}}
    end

    observation
    |> Ecto.Changeset.change(data: :no_allocation)
    |> Repo.update!()

    assert {:ok, _nodes} = Nodes.enroll([retired])
    assert %Node{status: :retired, max_biots: 20} = Repo.get!(Node, registration.node_id)
  end

  test "a rejected configuration leaves all node rows unchanged" do
    first = TestFixtures.registration(1)
    retired = TestFixtures.registration(2, status: :retired)
    assert {:ok, _nodes} = Nodes.enroll([first, retired])

    before = node_state()
    changed_first = %{first | max_biots: 99}
    invalid_second = %{retired | status: :enabled}

    assert Nodes.enroll([changed_first, invalid_second]) ==
             {:error, {:retired_cannot_enable, retired.node_id}}

    assert node_state() == before
  end

  defp node_state do
    from(node in Node,
      order_by: node.id,
      select: {node.id, node.registration, node.peer_identity, node.status, node.max_biots}
    )
    |> Repo.all()
  end
end
