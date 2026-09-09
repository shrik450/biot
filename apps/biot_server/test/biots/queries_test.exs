defmodule Biot.Server.Biots.QueriesTest do
  use Biot.Server.DataCase, async: false

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.BiotSpec
  alias Biot.Protocol.Desired
  alias Biot.Server.Biots
  alias Biot.Server.Biots.Accepted
  alias Biot.Server.Biots.SelectEnvironment
  alias Biot.Server.NodeConnections
  alias Biot.Server.Repo
  alias Biot.Server.Reports
  alias Biot.Server.Schema.Biot, as: BiotRow
  alias Biot.Server.Schema.Environment
  alias Biot.Server.Schema.Node
  alias Biot.Server.Schema.Operation
  alias Biot.Server.TestFixtures

  setup do
    owner = TestFixtures.principal(1)
    stranger = TestFixtures.principal(2)
    node = TestFixtures.node(1)
    actor = TestFixtures.actor(owner)
    biot_id = TestFixtures.id(BiotId, 9_001)

    on_exit(fn -> NodeConnections.delete(node.id) end)

    {:ok, %Accepted{}} =
      Biots.create(actor, biot_id, TestFixtures.create_command(name: "worker", node_id: node.id))

    %{
      owner: owner,
      actor: actor,
      stranger: TestFixtures.actor(stranger),
      node: node,
      biot_id: biot_id,
      connection_id: TestFixtures.connection_id(1)
    }
  end

  test "get returns the owner's biot with its intent and pending operation", context do
    assert {:ok, view} = Biots.get(context.actor, context.biot_id)

    biot = Repo.get!(BiotRow, context.biot_id)
    assert view.id == context.biot_id
    assert view.name == "worker"
    assert view.owner_id == context.owner.id
    assert view.node_id == context.node.id
    assert view.desired == BiotRow.desired(biot)

    assert view.desired == %Desired{
             revision: 1,
             state: :running,
             environment_id: biot.desired_environment_id
           }

    assert view.actual == :never_reported
    assert view.node == :unavailable
    assert view.operation.kind == :create
    assert view.operation.outcome == :pending
    assert view.access == %{revision: 1, enforcement: {:pending, context.node.id}}
    assert view.publications == []
    assert view.direct_secrets_ever_delivered == false
  end

  test "only the owner may read a biot", context do
    assert Biots.get(context.stranger, context.biot_id) == {:error, :forbidden}
    assert Biots.get(nil, context.biot_id) == {:error, :unauthenticated}
    assert Biots.get(context.actor, TestFixtures.id(BiotId, 9_999)) == {:error, :not_found}
  end

  test "a destroyed biot remains readable", context do
    assert {:ok, %Accepted{revision: 2}} = Biots.destroy(context.actor, context.biot_id)
    assert {:ok, view} = Biots.get(context.actor, context.biot_id)
    assert view.desired.state == :destroyed
  end

  test "an observation is current only on the node's live connection", context do
    report =
      TestFixtures.execution_report(accepted_revision: 1, container: :absent, data: :present)

    assert {:ok, :stored} =
             Reports.observation(context.node.id, context.connection_id, context.biot_id, report)

    assert {:ok, view} = Biots.get(context.actor, context.biot_id)
    assert view.actual.freshness == :stale
    assert view.actual.container == :absent
    assert view.actual.data == :present

    NodeConnections.put(context.node.id, %{
      connection_id: context.connection_id,
      state: :ready
    })

    assert {:ok, view} = Biots.get(context.actor, context.biot_id)
    assert view.actual.freshness == :current
    assert view.node == :ready

    NodeConnections.put(context.node.id, %{
      connection_id: TestFixtures.connection_id(2),
      state: :ready
    })

    assert {:ok, view} = Biots.get(context.actor, context.biot_id)
    assert view.actual.freshness == :stale
  end

  test "node status follows the operator status and the live connection", context do
    cases = [
      {:enabled, nil, :unavailable},
      {:enabled, :synchronizing, :connecting},
      {:enabled, :ready, :ready},
      {:disabled, :ready, :disabled},
      {:retired, :ready, :retired}
    ]

    for {status, connection_state, expected} <- cases do
      Repo.get!(Node, context.node.id)
      |> Ecto.Changeset.change(status: status)
      |> Repo.update!()

      case connection_state do
        nil ->
          NodeConnections.delete(context.node.id)

        state ->
          NodeConnections.put(context.node.id, %{
            connection_id: context.connection_id,
            state: state
          })
      end

      assert {:ok, view} = Biots.get(context.actor, context.biot_id)
      assert view.node == expected, "#{inspect(status)} with #{inspect(connection_state)}"
    end
  end

  test "the shown operation is the newest nonterminal one, else the newest terminal one",
       context do
    assert {:ok, view} = Biots.get(context.actor, context.biot_id)
    assert view.operation.target_revision == 1
    assert view.operation.outcome == :pending

    assert {:ok, %Accepted{revision: 2}} = Biots.stop(context.actor, context.biot_id, 1)

    assert {:ok, view} = Biots.get(context.actor, context.biot_id)
    assert view.operation.target_revision == 2
    assert view.operation.outcome == :pending

    set_outcome(context.biot_id, 2, :succeeded)

    assert {:ok, view} = Biots.get(context.actor, context.biot_id)
    assert view.operation.target_revision == 2
    assert view.operation.outcome == :succeeded

    assert {:ok, %Accepted{revision: 3}} = Biots.start(context.actor, context.biot_id, 2)

    assert {:ok, view} = Biots.get(context.actor, context.biot_id)
    assert view.operation.target_revision == 3
    assert view.operation.outcome == :pending
  end

  test "the newest nonterminal operation wins over an older nonterminal one", context do
    assert {:ok, %Accepted{revision: 2}} = Biots.stop(context.actor, context.biot_id, 1)
    set_outcome(context.biot_id, 1, :pending)

    assert {:ok, view} = Biots.get(context.actor, context.biot_id)
    assert view.operation.target_revision == 2
    assert view.operation.kind == :stop

    assert {:ok, [listed]} = Biots.list(context.actor, %{after: nil, limit: 10})
    assert listed.operation == view.operation
  end

  test "a nonterminal operation wins over a newer terminal one", context do
    assert {:ok, %Accepted{revision: 2}} = Biots.stop(context.actor, context.biot_id, 1)
    set_outcome(context.biot_id, 1, :pending)
    set_outcome(context.biot_id, 2, :succeeded)

    assert {:ok, view} = Biots.get(context.actor, context.biot_id)
    assert view.operation.target_revision == 1
    assert view.operation.outcome == :pending

    assert {:ok, [listed]} = Biots.list(context.actor, %{after: nil, limit: 10})
    assert listed.operation == view.operation
  end

  test "list shows only the caller's biots and pages by biot id", context do
    second = TestFixtures.id(BiotId, 9_002)
    third = TestFixtures.id(BiotId, 9_003)
    stranger_biot = TestFixtures.id(BiotId, 9_004)

    for {biot_id, name} <- [{second, "second"}, {third, "third"}] do
      command = TestFixtures.create_command(name: name, node_id: context.node.id)
      assert {:ok, %Accepted{}} = Biots.create(context.actor, biot_id, command)
    end

    stranger_command = TestFixtures.create_command(name: "theirs", node_id: context.node.id)
    assert {:ok, %Accepted{}} = Biots.create(context.stranger, stranger_biot, stranger_command)

    assert {:ok, views} = Biots.list(context.actor, %{after: nil, limit: 10})
    assert Enum.map(views, & &1.id) == [context.biot_id, second, third]

    assert {:ok, first_page} = Biots.list(context.actor, %{after: nil, limit: 2})
    assert Enum.map(first_page, & &1.id) == [context.biot_id, second]

    assert {:ok, next_page} = Biots.list(context.actor, %{after: second, limit: 2})
    assert Enum.map(next_page, & &1.id) == [third]

    assert {:ok, last_page} = Biots.list(context.actor, %{after: third, limit: 2})
    assert last_page == []

    assert {:ok, theirs} = Biots.list(context.stranger, %{after: nil, limit: 10})
    assert Enum.map(theirs, & &1.id) == [stranger_biot]

    assert Biots.list(nil, %{after: nil, limit: 10}) == {:error, :unauthenticated}
  end

  test "list projects each biot exactly as get does", context do
    second = TestFixtures.id(BiotId, 9_002)
    command = TestFixtures.create_command(name: "second", node_id: context.node.id)
    assert {:ok, %Accepted{}} = Biots.create(context.actor, second, command)

    assert {:ok, %Accepted{revision: 2}} = Biots.stop(context.actor, context.biot_id, 1)
    set_outcome(context.biot_id, 2, :succeeded)

    report =
      TestFixtures.execution_report(accepted_revision: 2, container: :absent, data: :present)

    assert {:ok, :stored} =
             Reports.observation(context.node.id, context.connection_id, context.biot_id, report)

    NodeConnections.put(context.node.id, %{
      connection_id: context.connection_id,
      state: :ready
    })

    assert {:ok, views} = Biots.list(context.actor, %{after: nil, limit: 10})

    for view <- views do
      assert {:ok, single} = Biots.get(context.actor, view.id)
      assert view == single
    end
  end

  test "a biot with no operation at all still projects", context do
    Repo.delete_all(Operation)

    assert {:ok, view} = Biots.get(context.actor, context.biot_id)
    assert view.operation == nil

    assert {:ok, [listed]} = Biots.list(context.actor, %{after: nil, limit: 10})
    assert listed.operation == nil
  end

  test "spec builds the node-facing intent and round-trips through its encoding", context do
    biot = Repo.get!(BiotRow, context.biot_id)
    environment = Repo.get!(Environment, biot.desired_environment_id)

    assert {:ok, %BiotSpec{} = spec} = Biots.spec(context.biot_id)
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

    assert {:ok, spec} = Biots.spec(context.biot_id)
    assert spec.execution.desired.revision == 2

    assert spec.execution.environment.id ==
             Repo.get!(BiotRow, context.biot_id).desired_environment_id

    assert BiotSpec.parse(BiotSpec.encode(spec)) == {:ok, spec}

    assert {:ok, %Accepted{revision: 3}} = Biots.destroy(context.actor, context.biot_id)

    assert {:ok, destroyed_spec} = Biots.spec(context.biot_id)
    assert destroyed_spec.execution.desired.state == :destroyed
    assert destroyed_spec.access_revision == 2
    assert BiotSpec.parse(BiotSpec.encode(destroyed_spec)) == {:ok, destroyed_spec}
  end

  test "spec for an unknown biot is not found" do
    assert Biots.spec(TestFixtures.id(BiotId, 9_999)) == {:error, :not_found}
  end

  defp set_outcome(biot_id, target_revision, outcome) do
    Repo.get_by!(Operation, biot_id: biot_id, target_revision: target_revision)
    |> Ecto.Changeset.change(outcome: outcome)
    |> Repo.update!()
  end
end
