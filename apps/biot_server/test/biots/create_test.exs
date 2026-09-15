defmodule Biot.Server.Biots.CreateTest do
  use Biot.Server.DataCase, async: false

  import Ecto.Query

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.NodeId
  alias Biot.Server.Actor
  alias Biot.Server.Biots
  alias Biot.Server.Biots.Accepted
  alias Biot.Server.Biots.CreationFingerprint
  alias Biot.Server.Biots.Unchanged
  alias Biot.Server.NodeConnections
  alias Biot.Server.Repo
  alias Biot.Server.Reports
  alias Biot.Server.Schema.Biot, as: BiotRow
  alias Biot.Server.Schema.Environment
  alias Biot.Server.Schema.Operation
  alias Biot.Server.TestFixtures

  setup do
    owner = TestFixtures.principal(1)
    node = TestFixtures.node(1)

    %{
      owner: owner,
      actor: TestFixtures.actor(owner),
      node: node,
      biot_id: TestFixtures.id(BiotId, 9_001),
      other_biot_id: TestFixtures.id(BiotId, 9_002)
    }
  end

  test "creation writes the biot, its environment, and a pending create operation", context do
    command = TestFixtures.create_command(name: "worker", node_id: context.node.id)

    assert {:ok, %Accepted{} = accepted} = Biots.create(context.actor, context.biot_id, command)
    assert accepted.biot_id == context.biot_id
    assert accepted.revision == 1

    biot = Repo.get!(BiotRow, context.biot_id)
    assert biot.name == TestFixtures.biot_name("worker")
    assert biot.owner_id == context.owner.id
    assert biot.node_id == context.node.id
    assert biot.repository == command.repository
    assert biot.creation_fingerprint == CreationFingerprint.compute(command)
    assert biot.desired_revision == 1
    assert biot.desired_state == :running
    assert biot.access_revision == 1

    environment = Repo.get!(Environment, biot.desired_environment_id)
    assert environment.biot_id == context.biot_id
    assert environment.selection == command.environment
    assert environment.resolution == :unresolved

    operation = Repo.get!(Operation, accepted.operation_id)
    assert operation.biot_id == context.biot_id
    assert operation.actor_id == context.owner.id
    assert operation.kind == :create
    assert operation.target_revision == 1
    assert operation.outcome == :pending
    assert operation.failure == nil
  end

  test "a stopped creation writes stopped intent and its own fingerprint", context do
    running = TestFixtures.create_command(name: "worker", node_id: context.node.id)

    stopped =
      TestFixtures.create_command(
        name: "worker",
        node_id: context.node.id,
        initial_state: :stopped
      )

    assert {:ok, %Accepted{revision: 1}} = Biots.create(context.actor, context.biot_id, stopped)

    biot = Repo.get!(BiotRow, context.biot_id)
    assert biot.desired_state == :stopped
    assert biot.desired_revision == 1
    assert biot.creation_fingerprint == CreationFingerprint.compute(stopped)
    refute biot.creation_fingerprint == CreationFingerprint.compute(running)

    operation = Repo.get_by!(Operation, biot_id: context.biot_id)
    assert operation.kind == :create
    assert operation.outcome == :pending
    assert operation.target_revision == 1
  end

  test "a stopped creation retried as a running creation conflicts", context do
    stopped =
      TestFixtures.create_command(
        name: "worker",
        node_id: context.node.id,
        initial_state: :stopped
      )

    assert {:ok, %Accepted{}} = Biots.create(context.actor, context.biot_id, stopped)

    running = TestFixtures.create_command(name: "worker", node_id: context.node.id)

    assert Biots.create(context.actor, context.biot_id, running) ==
             {:error, :creation_conflict}

    assert Repo.get!(BiotRow, context.biot_id).desired_state == :stopped
  end

  test "a new biot cannot be exposed to a directly delivered secret", context do
    command = TestFixtures.create_command(node_id: context.node.id)
    assert {:ok, %Accepted{}} = Biots.create(context.actor, context.biot_id, command)

    assert Repo.get!(BiotRow, context.biot_id).direct_secret_exposure_possible == false
  end

  test "a retry returns the pending operation and then reports unchanged", context do
    command = TestFixtures.create_command(node_id: context.node.id)

    assert {:ok, %Accepted{} = first} = Biots.create(context.actor, context.biot_id, command)
    assert {:ok, %Accepted{} = retry} = Biots.create(context.actor, context.biot_id, command)
    assert retry == first

    Operation
    |> Repo.get!(first.operation_id)
    |> Ecto.Changeset.change(outcome: :succeeded)
    |> Repo.update!()

    assert Biots.create(context.actor, context.biot_id, command) ==
             {:ok, %Unchanged{biot_id: context.biot_id, revision: 1}}

    assert Repo.aggregate(BiotRow, :count) == 1
    assert Repo.aggregate(Operation, :count) == 1
    assert Repo.aggregate(Environment, :count) == 1
  end

  test "the same id with a different body is a creation conflict", context do
    command = TestFixtures.create_command(name: "worker", node_id: context.node.id)
    assert {:ok, %Accepted{}} = Biots.create(context.actor, context.biot_id, command)

    conflicting = TestFixtures.create_command(name: "renamed", node_id: context.node.id)

    assert Biots.create(context.actor, context.biot_id, conflicting) ==
             {:error, :creation_conflict}

    assert Repo.get!(BiotRow, context.biot_id).name == TestFixtures.biot_name("worker")
    assert Repo.aggregate(Operation, :count) == 1
  end

  test "another actor cannot claim an existing biot id", context do
    command = TestFixtures.create_command(node_id: context.node.id)
    assert {:ok, %Accepted{}} = Biots.create(context.actor, context.biot_id, command)

    stranger = TestFixtures.actor(TestFixtures.principal(2))

    assert Biots.create(stranger, context.biot_id, command) == {:error, :creation_conflict}
    assert Repo.get!(BiotRow, context.biot_id).owner_id == context.owner.id
  end

  test "a live name is unique per owner while a destroyed name can be reused", context do
    command = TestFixtures.create_command(name: "shared", node_id: context.node.id)
    assert {:ok, %Accepted{}} = Biots.create(context.actor, context.biot_id, command)

    assert Biots.create(context.actor, context.other_biot_id, command) ==
             {:error, :name_conflict}

    other_owner = TestFixtures.actor(TestFixtures.principal(2))
    assert {:ok, %Accepted{}} = Biots.create(other_owner, context.other_biot_id, command)

    assert {:ok, %Accepted{}} = Biots.destroy(context.actor, context.biot_id)
    reused_id = TestFixtures.id(BiotId, 9_003)
    assert {:ok, %Accepted{}} = Biots.create(context.actor, reused_id, command)
  end

  test "a disabled or retired node rejects new biots", context do
    for {number, status} <- [{2, :disabled}, {3, :retired}] do
      node = TestFixtures.node(number, status: status)
      command = TestFixtures.create_command(name: "on-#{number}", node_id: node.id)
      biot_id = TestFixtures.id(BiotId, 9_100 + number)

      assert Biots.create(context.actor, biot_id, command) == {:error, :node_disabled}
      refute Repo.exists?(from(biot in BiotRow, where: biot.id == ^biot_id))
    end
  end

  test "an unknown node id is not found", context do
    unknown = TestFixtures.id(NodeId, 404)
    command = TestFixtures.create_command(node_id: unknown)

    assert Biots.create(context.actor, context.biot_id, command) == {:error, :not_found}
  end

  test "capacity counts every live biot on the assigned node", context do
    node = TestFixtures.node(2, max_biots: 1)

    first = TestFixtures.create_command(name: "first", node_id: node.id)
    second = TestFixtures.create_command(name: "second", node_id: node.id)

    assert {:ok, %Accepted{}} = Biots.create(context.actor, context.biot_id, first)

    assert Biots.create(context.actor, context.other_biot_id, second) ==
             {:error, :capacity_exceeded}
  end

  test "a destroyed biot holds capacity until the node reports no allocation", context do
    node = TestFixtures.node(2, max_biots: 1)
    connection_id = TestFixtures.connection_id(1)
    :ok = NodeConnections.put(node.id, %{connection_id: connection_id, state: :ready})
    on_exit(fn -> NodeConnections.delete(node.id) end)

    first = TestFixtures.create_command(name: "first", node_id: node.id)
    second = TestFixtures.create_command(name: "second", node_id: node.id)

    assert {:ok, %Accepted{}} = Biots.create(context.actor, context.biot_id, first)
    assert {:ok, %Accepted{revision: 2}} = Biots.destroy(context.actor, context.biot_id)

    assert Biots.create(context.actor, context.other_biot_id, second) ==
             {:error, :capacity_exceeded}

    still_allocated =
      TestFixtures.execution_report(
        accepted_revision: 2,
        container: :absent,
        data: :present
      )

    assert {:ok, :stored} =
             Reports.observation(node.id, connection_id, context.biot_id, still_allocated)

    assert Biots.create(context.actor, context.other_biot_id, second) ==
             {:error, :capacity_exceeded}

    released =
      TestFixtures.execution_report(
        accepted_revision: 2,
        container: :absent,
        data: :no_allocation
      )

    assert {:ok, :stored} = Reports.observation(node.id, connection_id, context.biot_id, released)

    assert {:ok, %Accepted{}} = Biots.create(context.actor, context.other_biot_id, second)
  end

  test "the default node comes from configuration", context do
    previous = Application.get_env(:biot_server, :default_node_id)
    on_exit(fn -> Application.put_env(:biot_server, :default_node_id, previous) end)

    command = TestFixtures.create_command(node_id: :default)

    Application.put_env(:biot_server, :default_node_id, nil)

    assert Biots.create(context.actor, context.biot_id, command) ==
             {:error, {:invalid_input, %{node_id: [:no_default_node]}}}

    Application.put_env(:biot_server, :default_node_id, context.node.id)
    assert {:ok, %Accepted{}} = Biots.create(context.actor, context.biot_id, command)
    assert Repo.get!(BiotRow, context.biot_id).node_id == context.node.id
  end

  test "an unauthenticated caller creates nothing", context do
    command = TestFixtures.create_command(node_id: context.node.id)

    assert Biots.create(nil, context.biot_id, command) == {:error, :unauthenticated}
    assert Repo.aggregate(BiotRow, :count) == 0
  end

  test "creation retries match on the actor as well as the body", context do
    command = TestFixtures.create_command(node_id: context.node.id)
    assert {:ok, %Accepted{}} = Biots.create(context.actor, context.biot_id, command)

    same_principal_again = %Actor{principal_id: context.owner.id}

    assert {:ok, %Accepted{}} =
             Biots.create(same_principal_again, context.biot_id, command)
  end
end
