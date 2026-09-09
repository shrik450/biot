defmodule Biot.Server.Queries.BiotsTest do
  use Biot.Server.DataCase, async: false

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.Desired
  alias Biot.Server.Access
  alias Biot.Server.Biots
  alias Biot.Server.Biots.Accepted
  alias Biot.Server.NodeConnections
  alias Biot.Server.Policy.Applied
  alias Biot.Server.Publications
  alias Biot.Server.Queries
  alias Biot.Server.Repo
  alias Biot.Server.Reports
  alias Biot.Server.Schema.Biot, as: BiotRow
  alias Biot.Server.Schema.Node
  alias Biot.Server.Schema.Operation
  alias Biot.Server.TestFixtures

  @page %{after: nil, limit: 10}

  setup do
    owner = TestFixtures.principal(1)
    collaborator = TestFixtures.principal(2)
    stranger = TestFixtures.principal(3)
    node = TestFixtures.node(1)
    actor = TestFixtures.actor(owner)
    biot_id = TestFixtures.id(BiotId, 9_001)

    on_exit(fn -> NodeConnections.delete(node.id) end)

    {:ok, %Accepted{}} =
      Biots.create(actor, biot_id, TestFixtures.create_command(name: "worker", node_id: node.id))

    %{
      owner: owner,
      actor: actor,
      collaborator: collaborator,
      collaborator_actor: TestFixtures.actor(collaborator),
      stranger_actor: TestFixtures.actor(stranger),
      node: node,
      biot_id: biot_id,
      connection_id: TestFixtures.connection_id(1),
      low_port: TestFixtures.port(4_000),
      high_port: TestFixtures.port(5_000)
    }
  end

  test "get returns the owner's biot with its intent, role, and pending operation", context do
    assert {:ok, view} = Queries.Biots.get(context.actor, context.biot_id)

    biot = Repo.get!(BiotRow, context.biot_id)
    assert view.id == context.biot_id
    assert view.name == "worker"
    assert view.owner_id == context.owner.id
    assert view.node_id == context.node.id
    assert view.role == :owner
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
    assert view.direct_secret_exposure_possible == false
  end

  test "get tells an unknown biot apart from one the actor may not read", context do
    assert Queries.Biots.get(context.stranger_actor, context.biot_id) == {:error, :forbidden}

    assert Queries.Biots.get(context.actor, TestFixtures.id(BiotId, 9_999)) ==
             {:error, :not_found}

    assert Queries.Biots.get(context.stranger_actor, TestFixtures.id(BiotId, 9_999)) ==
             {:error, :not_found}

    assert Queries.Biots.get(nil, context.biot_id) == {:error, :unauthenticated}
  end

  test "a shell grant makes the holder a collaborator who sees no publications", context do
    publish(context, context.low_port)

    assert {:ok, %Applied{}} =
             Access.grant_shell(context.actor, context.biot_id, context.collaborator.id)

    assert {:ok, view} = Queries.Biots.get(context.collaborator_actor, context.biot_id)
    assert view.role == {:collaborator, %{shell: true, view_ports: []}}
    assert view.publications == []
  end

  test "a view grant shows only the granted port to the collaborator", context do
    publish(context, context.low_port)
    publish(context, context.high_port)
    grant_view(context, context.low_port)

    assert {:ok, owner_view} = Queries.Biots.get(context.actor, context.biot_id)
    assert Enum.map(owner_view.publications, & &1.port) == [context.low_port, context.high_port]

    assert {:ok, view} = Queries.Biots.get(context.collaborator_actor, context.biot_id)

    assert view.role ==
             {:collaborator, %{shell: false, view_ports: [context.low_port]}}

    assert Enum.map(view.publications, & &1.port) == [context.low_port]
  end

  test "unpublishing a port removes it from the owner's view", context do
    publish(context, context.low_port)
    publish(context, context.high_port)

    assert {:ok, %Applied{}} =
             Publications.unpublish(context.actor, context.biot_id, context.low_port)

    assert {:ok, view} = Queries.Biots.get(context.actor, context.biot_id)
    assert Enum.map(view.publications, & &1.port) == [context.high_port]
  end

  test "list covers owned biots, shell grants, and view grants but not strangers", context do
    shell_only = create(context, 9_002, "shell-only")
    view_only = create(context, 9_003, "view-only")
    hidden = create(context, 9_004, "hidden")

    assert {:ok, %Applied{}} =
             Access.grant_shell(context.actor, shell_only, context.collaborator.id)

    assert {:ok, %Applied{}} = Publications.publish(context.actor, view_only, context.low_port)

    assert {:ok, %Applied{}} =
             Access.grant_view(
               context.actor,
               view_only,
               context.low_port,
               context.collaborator.id
             )

    assert {:ok, owned} = Queries.Biots.list(context.actor, @page)

    assert Enum.map(owned, & &1.id) == [
             context.biot_id,
             shell_only,
             view_only,
             hidden
           ]

    assert Enum.map(owned, & &1.role) == List.duplicate(:owner, 4)

    assert {:ok, shared} = Queries.Biots.list(context.collaborator_actor, @page)
    assert Enum.map(shared, & &1.id) == [shell_only, view_only]

    assert Enum.map(shared, & &1.role) == [
             {:collaborator, %{shell: true, view_ports: []}},
             {:collaborator, %{shell: false, view_ports: [context.low_port]}}
           ]

    assert Enum.map(shared, & &1.publications) == [[], [publication_view(context, view_only)]]

    assert Queries.Biots.list(context.stranger_actor, @page) == {:ok, []}
    assert Queries.Biots.list(nil, @page) == {:error, :unauthenticated}
  end

  test "a biot with two view grants for the actor fills only one page slot", context do
    second = create(context, 9_002, "second")
    publish(context, context.low_port)
    publish(context, context.high_port)
    grant_view(context, context.low_port)
    grant_view(context, context.high_port)

    assert {:ok, %Applied{}} = Publications.publish(context.actor, second, context.low_port)

    assert {:ok, %Applied{}} =
             Access.grant_view(context.actor, second, context.low_port, context.collaborator.id)

    assert {:ok, both} = Queries.Biots.list(context.collaborator_actor, @page)
    assert Enum.map(both, & &1.id) == [context.biot_id, second]

    assert {:ok, first_page} =
             Queries.Biots.list(context.collaborator_actor, %{after: nil, limit: 1})

    assert Enum.map(first_page, & &1.id) == [context.biot_id]

    assert Enum.map(hd(first_page).publications, & &1.port) == [
             context.low_port,
             context.high_port
           ]

    assert {:ok, next_page} =
             Queries.Biots.list(context.collaborator_actor, %{after: context.biot_id, limit: 1})

    assert Enum.map(next_page, & &1.id) == [second]

    assert {:ok, last_page} =
             Queries.Biots.list(context.collaborator_actor, %{after: second, limit: 1})

    assert last_page == []
  end

  test "list pages by biot id for the owner", context do
    second = create(context, 9_002, "second")
    third = create(context, 9_003, "third")

    assert {:ok, first_page} = Queries.Biots.list(context.actor, %{after: nil, limit: 2})
    assert Enum.map(first_page, & &1.id) == [context.biot_id, second]

    assert {:ok, next_page} = Queries.Biots.list(context.actor, %{after: second, limit: 2})
    assert Enum.map(next_page, & &1.id) == [third]

    assert {:ok, last_page} = Queries.Biots.list(context.actor, %{after: third, limit: 2})
    assert last_page == []
  end

  test "list projects each biot exactly as get does", context do
    create(context, 9_002, "second")
    publish(context, context.low_port)
    grant_view(context, context.low_port)

    assert {:ok, %Accepted{revision: 2}} = Biots.stop(context.actor, context.biot_id, 1)

    report =
      TestFixtures.execution_report(accepted_revision: 2, container: :absent, data: :present)

    assert {:ok, :stored} =
             Reports.observation(context.node.id, context.connection_id, context.biot_id, report)

    NodeConnections.put(context.node.id, %{
      connection_id: context.connection_id,
      state: :ready
    })

    for actor <- [context.actor, context.collaborator_actor] do
      assert {:ok, views} = Queries.Biots.list(actor, @page)

      for view <- views do
        assert {:ok, single} = Queries.Biots.get(actor, view.id)
        assert view == single
      end
    end
  end

  test "a destroyed biot stays readable with no publications", context do
    publish(context, context.low_port)
    grant_view(context, context.low_port)

    assert {:ok, %Accepted{revision: 2}} = Biots.destroy(context.actor, context.biot_id)

    assert {:ok, view} = Queries.Biots.get(context.actor, context.biot_id)
    assert view.desired.state == :destroyed
    assert view.publications == []
    assert view.access.revision == 2

    assert Queries.Biots.list(context.collaborator_actor, @page) == {:ok, []}
  end

  test "an observation is current only on the node's live connection", context do
    report =
      TestFixtures.execution_report(accepted_revision: 1, container: :absent, data: :present)

    assert {:ok, :stored} =
             Reports.observation(context.node.id, context.connection_id, context.biot_id, report)

    assert {:ok, view} = Queries.Biots.get(context.actor, context.biot_id)
    assert view.actual.freshness == :stale
    assert view.actual.container == :absent
    assert view.actual.data == :present

    NodeConnections.put(context.node.id, %{
      connection_id: context.connection_id,
      state: :ready
    })

    assert {:ok, view} = Queries.Biots.get(context.actor, context.biot_id)
    assert view.actual.freshness == :current
    assert view.node == :ready

    NodeConnections.put(context.node.id, %{
      connection_id: TestFixtures.connection_id(2),
      state: :ready
    })

    assert {:ok, view} = Queries.Biots.get(context.actor, context.biot_id)
    assert view.actual.freshness == :stale
  end

  test "node status follows the operator status and the live connection", context do
    cases = [
      {:enabled, nil, :unavailable},
      {:enabled, :synchronizing, :connecting},
      {:enabled, :ready, :ready},
      {:disabled, :ready, :disabled},
      {:retired, :ready, :retired},
      {:abandoned, :ready, :abandoned}
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

      assert {:ok, view} = Queries.Biots.get(context.actor, context.biot_id)
      assert view.node == expected, "#{inspect(status)} with #{inspect(connection_state)}"
    end
  end

  test "the shown operation is the newest nonterminal one, else the newest terminal one",
       context do
    assert {:ok, view} = Queries.Biots.get(context.actor, context.biot_id)
    assert view.operation.target_revision == 1
    assert view.operation.outcome == :pending

    assert {:ok, %Accepted{revision: 2}} = Biots.stop(context.actor, context.biot_id, 1)

    assert {:ok, view} = Queries.Biots.get(context.actor, context.biot_id)
    assert view.operation.target_revision == 2
    assert view.operation.outcome == :pending

    set_outcome(context.biot_id, 2, :succeeded)

    assert {:ok, view} = Queries.Biots.get(context.actor, context.biot_id)
    assert view.operation.target_revision == 2
    assert view.operation.outcome == :succeeded

    assert {:ok, %Accepted{revision: 3}} = Biots.start(context.actor, context.biot_id, 2)

    assert {:ok, view} = Queries.Biots.get(context.actor, context.biot_id)
    assert view.operation.target_revision == 3
    assert view.operation.outcome == :pending
  end

  test "the newest nonterminal operation wins over an older nonterminal one", context do
    assert {:ok, %Accepted{revision: 2}} = Biots.stop(context.actor, context.biot_id, 1)
    set_outcome(context.biot_id, 1, :pending)

    assert {:ok, view} = Queries.Biots.get(context.actor, context.biot_id)
    assert view.operation.target_revision == 2
    assert view.operation.kind == :stop

    assert {:ok, [listed]} = Queries.Biots.list(context.actor, @page)
    assert listed.operation == view.operation
  end

  test "a nonterminal operation wins over a newer terminal one", context do
    assert {:ok, %Accepted{revision: 2}} = Biots.stop(context.actor, context.biot_id, 1)
    set_outcome(context.biot_id, 1, :pending)
    set_outcome(context.biot_id, 2, :succeeded)

    assert {:ok, view} = Queries.Biots.get(context.actor, context.biot_id)
    assert view.operation.target_revision == 1
    assert view.operation.outcome == :pending

    assert {:ok, [listed]} = Queries.Biots.list(context.actor, @page)
    assert listed.operation == view.operation
  end

  test "a biot with no operation at all still projects", context do
    Repo.delete_all(Operation)

    assert {:ok, view} = Queries.Biots.get(context.actor, context.biot_id)
    assert view.operation == nil

    assert {:ok, [listed]} = Queries.Biots.list(context.actor, @page)
    assert listed.operation == nil
  end

  defp create(context, number, name) do
    biot_id = TestFixtures.id(BiotId, number)
    command = TestFixtures.create_command(name: name, node_id: context.node.id)

    assert {:ok, %Accepted{}} = Biots.create(context.actor, biot_id, command)
    biot_id
  end

  defp publish(context, port) do
    assert {:ok, %Applied{}} = Publications.publish(context.actor, context.biot_id, port)
  end

  defp grant_view(context, port) do
    assert {:ok, %Applied{}} =
             Access.grant_view(context.actor, context.biot_id, port, context.collaborator.id)
  end

  defp publication_view(context, biot_id) do
    assert {:ok, [view]} = Publications.discover(context.actor, biot_id)
    view
  end

  defp set_outcome(biot_id, target_revision, outcome) do
    Repo.get_by!(Operation, biot_id: biot_id, target_revision: target_revision)
    |> Ecto.Changeset.change(outcome: outcome)
    |> Repo.update!()
  end
end
