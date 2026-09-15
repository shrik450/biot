defmodule Biot.Server.NodesTest do
  use Biot.Server.DataCase, async: false

  import Ecto.Query

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.Failure
  alias Biot.Server.Access
  alias Biot.Server.Biots
  alias Biot.Server.Biots.Accepted
  alias Biot.Server.Biots.SelectEnvironment
  alias Biot.Server.Nodes
  alias Biot.Server.NodeWake
  alias Biot.Server.Publications
  alias Biot.Server.Repo
  alias Biot.Server.Schema.Biot, as: BiotRow
  alias Biot.Server.Schema.Node
  alias Biot.Server.Schema.Operation
  alias Biot.Server.Schema.Publication
  alias Biot.Server.Schema.ShellGrant
  alias Biot.Server.Schema.ViewGrant
  alias Biot.Server.TestFixtures

  setup do
    previous = Application.fetch_env(:biot_server, :node_registrations_file)

    on_exit(fn ->
      restore_env(:node_registrations_file, previous)
    end)

    :ok
  end

  test "reload inserts, repeats, disables an omission, and retires" do
    enabled = TestFixtures.registration(1)

    assert {:ok, [_node]} = reload([enabled])
    assert %Node{status: :enabled} = Repo.get!(Node, enabled.node_id)

    assert {:ok, [_node]} = reload([enabled])
    assert %Node{status: :enabled} = Repo.get!(Node, enabled.node_id)

    assert {:ok, [_node]} = reload([])
    assert %Node{status: :disabled} = Repo.get!(Node, enabled.node_id)

    retired = %{enabled | status: :retired}
    assert {:ok, [_node]} = reload([retired])
    assert %Node{status: :retired} = Repo.get!(Node, enabled.node_id)

    assert {:error, rejection} = reload([enabled])
    assert rejection == {:terminal_node_locked, enabled.node_id, :retired}
    assert Nodes.message(rejection) =~ to_string(enabled.node_id)
    assert %Node{status: :retired} = Repo.get!(Node, enabled.node_id)
  end

  test "enabled to disabled revokes access while disabled to enabled does not" do
    first = TestFixtures.registration(1)
    second = TestFixtures.registration(2)
    assert {:ok, _nodes} = reload([first, second])

    owner = TestFixtures.principal(1)
    actor = TestFixtures.actor(owner)
    first_biot = create_biot(actor, first.node_id, 1, "first")
    second_biot = create_biot(actor, first.node_id, 2, "second")
    other_biot = create_biot(actor, second.node_id, 3, "other")

    assert {:ok, _nodes} = reload([%{first | status: :disabled}, second])
    assert access_revision(first_biot) == 2
    assert access_revision(second_biot) == 2
    assert access_revision(other_biot) == 1

    assert {:ok, _nodes} = reload([first, second])
    assert access_revision(first_biot) == 2
    assert access_revision(second_biot) == 2
    assert access_revision(other_biot) == 1
  end

  test "omission changes only enabled nodes" do
    registrations = [
      TestFixtures.registration(1),
      TestFixtures.registration(2, status: :disabled),
      TestFixtures.registration(3, status: :retired),
      TestFixtures.registration(4, status: :abandoned)
    ]

    assert {:ok, _nodes} = reload(registrations)
    assert {:ok, _nodes} = reload([])

    assert Enum.map(registrations, &Repo.get!(Node, &1.node_id).status) ==
             [:disabled, :disabled, :retired, :abandoned]
  end

  test "retirement requires every assigned Biot to report no allocation" do
    registration = TestFixtures.registration(1)
    assert {:ok, _nodes} = reload([registration])
    owner = TestFixtures.principal(1)
    actor = TestFixtures.actor(owner)
    biot_id = create_biot(actor, registration.node_id, 1, "retirement")
    retired = %{registration | status: :retired, max_biots: 20}

    assert reload([retired]) == {:error, {:retirement_blocked, registration.node_id}}
    assert %Node{status: :enabled, max_biots: 10} = Repo.get!(Node, registration.node_id)

    biot = Repo.get!(BiotRow, biot_id)
    observation = TestFixtures.observation(biot, 1, data: :unknown)

    for data <- [:unknown, :uninitialized, :present, :lost] do
      observation |> Ecto.Changeset.change(data: data) |> Repo.update!()
      assert reload([retired]) == {:error, {:retirement_blocked, registration.node_id}}
    end

    observation |> Ecto.Changeset.change(data: :no_allocation) |> Repo.update!()
    assert {:ok, _nodes} = reload([retired])
    assert %Node{status: :retired, max_biots: 20} = Repo.get!(Node, registration.node_id)
  end

  test "retirement waits until the node's latest report lists no orphaned allocation" do
    registration = TestFixtures.registration(1)
    assert {:ok, _nodes} = reload([registration])
    node = Repo.get!(Node, registration.node_id)
    retired = %{registration | status: :retired}

    report =
      TestFixtures.node_observation(node, 1,
        orphaned_allocations: [TestFixtures.orphaned_allocation(1)]
      )

    assert reload([retired]) == {:error, {:retirement_blocked, registration.node_id}}
    assert %Node{status: :enabled} = Repo.get!(Node, registration.node_id)

    report |> Ecto.Changeset.change(orphaned_allocations: []) |> Repo.update!()
    assert {:ok, _nodes} = reload([retired])
    assert %Node{status: :retired} = Repo.get!(Node, registration.node_id)
  end

  test "abandonment fails only active assigned operations and increments each assigned Biot once" do
    assigned = TestFixtures.registration(1)
    other = TestFixtures.registration(2)
    assert {:ok, _nodes} = reload([assigned, other])
    owner = TestFixtures.principal(1)
    actor = TestFixtures.actor(owner)

    outcomes = [:pending, :working, :succeeded, :failed, :superseded]

    assigned_operations =
      for {outcome, number} <- Enum.with_index(outcomes, 1), into: %{} do
        biot_id = create_biot(actor, assigned.node_id, number, "assigned-#{outcome}")
        operation = only_operation(biot_id)
        failure = if outcome == :failed, do: TestFixtures.failure(), else: nil

        operation
        |> Ecto.Changeset.change(outcome: outcome, failure: failure)
        |> Repo.update!()

        {outcome, {biot_id, operation.id, failure}}
      end

    other_biot = create_biot(actor, other.node_id, 20, "other")
    other_operation = only_operation(other_biot)

    assert {:ok, _nodes} = reload([%{assigned | status: :abandoned}, other])

    expected_failure = %Failure{
      stage: :node,
      code: :node_abandoned,
      retry: :operator,
      message: "the assigned node was abandoned",
      diagnostic_ref: nil
    }

    for {outcome, {biot_id, operation_id, original_failure}} <- assigned_operations do
      stored = Repo.get!(Operation, operation_id)

      if outcome in [:pending, :working] do
        assert stored.outcome == :failed
        assert stored.failure == expected_failure
      else
        assert stored.outcome == outcome
        assert stored.failure == original_failure
      end

      assert access_revision(biot_id) == 2
    end

    assert Repo.get!(Operation, other_operation.id).outcome == :pending
    assert access_revision(other_biot) == 1
  end

  test "an abandoned node rejects work and destroy records the loss without waking" do
    registration = TestFixtures.registration(1)
    assert {:ok, _nodes} = reload([registration])
    owner = TestFixtures.principal(1)
    collaborator = TestFixtures.principal(2)
    actor = TestFixtures.actor(owner)
    biot_id = create_biot(actor, registration.node_id, 1, "abandoned")

    assert {:ok, _nodes} = reload([%{registration | status: :abandoned}])

    command = %SelectEnvironment{selection: TestFixtures.selection()}
    assert Biots.start(actor, biot_id, 1) == {:error, :node_abandoned}
    assert Biots.stop(actor, biot_id, 1) == {:error, :node_abandoned}
    assert Biots.update_environment(actor, biot_id, command, 1) == {:error, :node_abandoned}

    assert Biots.create(
             actor,
             TestFixtures.id(BiotId, 9_999),
             TestFixtures.create_command(name: "rejected", node_id: registration.node_id)
           ) == {:error, :node_abandoned}

    port = TestFixtures.port(4_000)
    assert {:ok, _result} = Publications.publish(actor, biot_id, port)
    assert {:ok, _result} = Access.grant_shell(actor, biot_id, collaborator.id)
    assert {:ok, _result} = Access.grant_view(actor, biot_id, port, collaborator.id)
    :ok = NodeWake.subscribe(registration.node_id)

    assert {:ok, %Accepted{operation_id: operation_id, revision: 2}} =
             Biots.destroy(actor, biot_id)

    refute_receive {:biot_spec_changed, ^biot_id}, 100

    destroyed = Repo.get!(BiotRow, biot_id)
    operation = Repo.get!(Operation, operation_id)
    assert destroyed.desired_state == :destroyed
    assert destroyed.access_revision == 3
    assert operation.kind == :destroy
    assert operation.outcome == :failed
    assert operation.failure == Nodes.abandonment_failure()

    assert Repo.all(from(publication in Publication, where: publication.biot_id == ^biot_id))
           |> Enum.map(& &1.state) == [:inactive]

    refute Repo.exists?(from(grant in ShellGrant, where: grant.biot_id == ^biot_id))
    refute Repo.exists?(from(grant in ViewGrant, where: grant.biot_id == ^biot_id))
  end

  test "disabled nodes accept lifecycle changes but disabled and retired nodes reject creation" do
    disabled = TestFixtures.registration(1, status: :disabled)
    retired = TestFixtures.registration(2, status: :retired)
    enabled = TestFixtures.registration(3)
    assert {:ok, _nodes} = reload([disabled, retired, enabled])
    owner = TestFixtures.principal(1)
    actor = TestFixtures.actor(owner)
    biot_id = create_biot(actor, enabled.node_id, 1, "lifecycle")
    assert {:ok, _nodes} = reload([disabled, retired, %{enabled | status: :disabled}])
    :ok = NodeWake.subscribe(enabled.node_id)

    assert {:ok, %Accepted{revision: 2}} = Biots.stop(actor, biot_id, 1)
    assert_receive {:biot_spec_changed, ^biot_id}
    assert {:ok, %Accepted{revision: 3}} = Biots.start(actor, biot_id, 2)
    assert_receive {:biot_spec_changed, ^biot_id}

    for {number, node_id} <- [{2, disabled.node_id}, {3, retired.node_id}] do
      assert Biots.create(
               actor,
               TestFixtures.id(BiotId, 9_900 + number),
               TestFixtures.create_command(name: "blocked-#{number}", node_id: node_id)
             ) == {:error, :node_disabled}
    end
  end

  @tag :tmp_dir
  test "every invalid reload leaves nodes, operations, and access revisions unchanged", %{
    tmp_dir: tmp_dir
  } do
    first = TestFixtures.registration(1)
    second = TestFixtures.registration(2)
    retired = TestFixtures.registration(3, status: :retired)
    abandoned = TestFixtures.registration(4, status: :abandoned)
    assert {:ok, _nodes} = reload([first, second, retired, abandoned])
    owner = TestFixtures.principal(1)
    actor = TestFixtures.actor(owner)
    _biot_id = create_biot(actor, first.node_id, 1, "snapshot")
    before = state_snapshot()

    invalid_configurations = [
      [%{first | registration_id: second.registration_id}, second, retired, abandoned],
      [first, %{second | registration_id: first.registration_id}, retired, abandoned],
      [%{first | peer_identity: second.peer_identity}, second, retired, abandoned],
      [first, second, %{retired | status: :enabled}, abandoned],
      [first, second, retired, %{abandoned | status: :enabled}],
      [first, second, %{retired | status: :abandoned}, abandoned],
      [first, second, retired, %{abandoned | status: :retired}],
      [first, second, retired, abandoned, first],
      [
        first,
        second,
        retired,
        abandoned,
        %{second | node_id: TestFixtures.id(Biot.Protocol.NodeId, 9)}
      ],
      [
        first,
        second,
        retired,
        abandoned,
        %{
          second
          | node_id: TestFixtures.id(Biot.Protocol.NodeId, 9),
            peer_identity: first.peer_identity
        }
      ]
    ]

    for registrations <- invalid_configurations do
      assert {:error, rejection} = reload(registrations)
      assert is_binary(Nodes.message(rejection))
      assert state_snapshot() == before
    end

    first_node_id = first.node_id

    assert {:error, {:retirement_blocked, ^first_node_id} = rejection} =
             reload([%{first | status: :retired}, second, retired, abandoned])

    assert is_binary(Nodes.message(rejection))
    assert state_snapshot() == before

    invalid_json = Path.join(tmp_dir, "invalid.json")
    File.write!(invalid_json, "[")
    on_exit(fn -> File.rm(invalid_json) end)
    Application.delete_env(:biot_server, :node_registrations_file)
    Application.put_env(:biot_server, :node_registrations_file, invalid_json)

    assert {:error, {:enrollment_file, _error} = rejection} = Nodes.reload()
    assert Nodes.message(rejection) =~ "invalid JSON"
    assert state_snapshot() == before
  end

  test "message returns text for every rejection shape" do
    id = TestFixtures.id(Biot.Protocol.NodeId, 1)

    rejections = [
      {:duplicate_node, id},
      {:duplicate_registration, id},
      {:duplicate_peer_identity, id},
      {:rebinding, id},
      {:terminal_node_locked, id, :retired},
      {:terminal_node_locked, id, :abandoned},
      {:retirement_blocked, id},
      {:enrollment_file, {:invalid_json, "bad input"}},
      {:persistence_failed, id}
    ]

    for rejection <- rejections do
      message = Nodes.message(rejection)
      assert message != ""
    end
  end

  defp reload(registrations) do
    TestFixtures.put_registrations(registrations)
    Nodes.reload()
  end

  defp create_biot(actor, node_id, number, name) do
    biot_id = TestFixtures.id(BiotId, 2_000 + number)

    assert {:ok, %Accepted{}} =
             Biots.create(
               actor,
               biot_id,
               TestFixtures.create_command(name: name, node_id: node_id)
             )

    biot_id
  end

  defp only_operation(biot_id) do
    Repo.one!(from(operation in Operation, where: operation.biot_id == ^biot_id))
  end

  defp access_revision(biot_id), do: Repo.get!(BiotRow, biot_id).access_revision

  defp state_snapshot do
    nodes =
      Node
      |> order_by([node], node.id)
      |> Repo.all()
      |> Enum.map(&{&1.id, &1.registration, &1.peer_identity, &1.status, &1.max_biots})

    operations =
      Operation
      |> order_by([operation], operation.id)
      |> Repo.all()
      |> Enum.map(&{&1.id, &1.outcome, &1.failure})

    revisions =
      BiotRow
      |> order_by([biot], biot.id)
      |> Repo.all()
      |> Enum.map(&{&1.id, &1.access_revision})

    {nodes, operations, revisions}
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:biot_server, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:biot_server, key)
end
