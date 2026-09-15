defmodule Biot.Server.Biots.LifecycleTest do
  use Biot.Server.DataCase, async: false

  import Ecto.Query

  alias Biot.Protocol.BiotId
  alias Biot.Server.Biots
  alias Biot.Server.Biots.Accepted
  alias Biot.Server.Biots.SelectEnvironment
  alias Biot.Server.Biots.Unchanged
  alias Biot.Server.Repo
  alias Biot.Server.Schema.Biot, as: BiotRow
  alias Biot.Server.Schema.Environment
  alias Biot.Server.Schema.Operation
  alias Biot.Server.Schema.Publication
  alias Biot.Server.Schema.ShellGrant
  alias Biot.Server.Schema.ViewGrant
  alias Biot.Server.TestFixtures

  setup do
    owner = TestFixtures.principal(1)
    stranger = TestFixtures.principal(2)
    node = TestFixtures.node(1)
    biot_id = TestFixtures.id(BiotId, 9_001)
    actor = TestFixtures.actor(owner)

    {:ok, %Accepted{}} =
      Biots.create(actor, biot_id, TestFixtures.create_command(node_id: node.id))

    %{
      owner: owner,
      actor: actor,
      stranger: TestFixtures.actor(stranger),
      stranger_principal: stranger,
      node: node,
      biot_id: biot_id
    }
  end

  test "stop and start move desired state and revision one step at a time", context do
    assert {:ok, %Accepted{revision: 2}} = Biots.stop(context.actor, context.biot_id, 1)
    assert desired(context.biot_id) == {2, :stopped}

    assert {:ok, %Accepted{revision: 3}} = Biots.start(context.actor, context.biot_id, 2)
    assert desired(context.biot_id) == {3, :running}
  end

  test "a request that matches current intent is unchanged", context do
    assert Biots.start(context.actor, context.biot_id, 1) ==
             {:ok, %Unchanged{biot_id: context.biot_id, revision: 1}}

    assert desired(context.biot_id) == {1, :running}
    assert operation_count(context.biot_id) == 1

    assert {:ok, %Accepted{revision: 2}} = Biots.stop(context.actor, context.biot_id, 1)

    assert Biots.stop(context.actor, context.biot_id, 2) ==
             {:ok, %Unchanged{biot_id: context.biot_id, revision: 2}}

    assert operation_count(context.biot_id) == 2
  end

  test "a stale expected revision conflicts and reports the current revision", context do
    assert {:ok, %Accepted{revision: 2}} = Biots.stop(context.actor, context.biot_id, 1)

    for change <- [:start, :stop, :update_environment] do
      assert apply_change(context.actor, context.biot_id, change, 1) ==
               {:error, {:revision_conflict, 2}}
    end

    assert desired(context.biot_id) == {2, :stopped}
    assert operation_count(context.biot_id) == 2
  end

  test "update_environment inserts a new environment and selects it", context do
    original = Repo.get!(BiotRow, context.biot_id).desired_environment_id
    selection = TestFixtures.selection()
    command = %SelectEnvironment{selection: selection}

    assert {:ok, %Accepted{revision: 2}} =
             Biots.update_environment(context.actor, context.biot_id, command, 1)

    biot = Repo.get!(BiotRow, context.biot_id)
    refute biot.desired_environment_id == original
    assert biot.desired_state == :running

    environment = Repo.get!(Environment, biot.desired_environment_id)
    assert environment.biot_id == context.biot_id
    assert environment.selection == selection
    assert environment.resolution == :unresolved

    assert Repo.aggregate(from(e in Environment, where: e.biot_id == ^context.biot_id), :count) ==
             2
  end

  test "update_environment keeps a stopped biot stopped", context do
    assert {:ok, %Accepted{revision: 2}} = Biots.stop(context.actor, context.biot_id, 1)

    command = %SelectEnvironment{selection: TestFixtures.selection()}

    assert {:ok, %Accepted{revision: 3}} =
             Biots.update_environment(context.actor, context.biot_id, command, 2)

    assert desired(context.biot_id) == {3, :stopped}
  end

  test "committing a revision supersedes lower pending and working operations", context do
    create_operation = only_operation(context.biot_id, 1)
    assert create_operation.outcome == :pending

    assert {:ok, %Accepted{revision: 2}} = Biots.stop(context.actor, context.biot_id, 1)
    assert only_operation(context.biot_id, 1).outcome == :superseded

    only_operation(context.biot_id, 2)
    |> Ecto.Changeset.change(outcome: :working)
    |> Repo.update!()

    assert {:ok, %Accepted{revision: 3}} = Biots.start(context.actor, context.biot_id, 2)

    assert only_operation(context.biot_id, 1).outcome == :superseded
    assert only_operation(context.biot_id, 2).outcome == :superseded
    assert only_operation(context.biot_id, 3).outcome == :pending
  end

  test "a terminal operation keeps its outcome across later revisions", context do
    only_operation(context.biot_id, 1)
    |> Ecto.Changeset.change(outcome: :succeeded)
    |> Repo.update!()

    assert {:ok, %Accepted{revision: 2}} = Biots.stop(context.actor, context.biot_id, 1)
    assert only_operation(context.biot_id, 1).outcome == :succeeded

    failure = TestFixtures.failure()

    only_operation(context.biot_id, 2)
    |> Ecto.Changeset.change(outcome: :failed, failure: failure)
    |> Repo.update!()

    assert {:ok, %Accepted{revision: 3}} = Biots.start(context.actor, context.biot_id, 2)

    stored = only_operation(context.biot_id, 2)
    assert stored.outcome == :failed
    assert stored.failure == failure
  end

  test "every lifecycle change other than destroy rejects a destroyed biot", context do
    assert {:ok, %Accepted{revision: 2}} = Biots.destroy(context.actor, context.biot_id)

    for change <- [:start, :stop, :update_environment] do
      assert apply_change(context.actor, context.biot_id, change, 2) == {:error, :destroyed}
    end

    assert desired(context.biot_id) == {2, :destroyed}
    assert operation_count(context.biot_id) == 2
  end

  test "destroy is accepted from running and from stopped", context do
    assert {:ok, %Accepted{revision: 2}} = Biots.destroy(context.actor, context.biot_id)
    assert only_operation(context.biot_id, 2).kind == :destroy

    other_id = TestFixtures.id(BiotId, 9_002)
    command = TestFixtures.create_command(name: "second", node_id: context.node.id)
    assert {:ok, %Accepted{}} = Biots.create(context.actor, other_id, command)
    assert {:ok, %Accepted{revision: 2}} = Biots.stop(context.actor, other_id, 1)
    assert {:ok, %Accepted{revision: 3}} = Biots.destroy(context.actor, other_id)
    assert desired(other_id) == {3, :destroyed}
  end

  test "destroying an already destroyed biot is unchanged", context do
    assert {:ok, %Accepted{revision: 2}} = Biots.destroy(context.actor, context.biot_id)

    assert Biots.destroy(context.actor, context.biot_id) ==
             {:ok, %Unchanged{biot_id: context.biot_id, revision: 2}}

    assert Repo.get!(BiotRow, context.biot_id).access_revision == 2
    assert operation_count(context.biot_id) == 2
  end

  test "destroy removes only this biot's publications and grants", context do
    other_id = TestFixtures.id(BiotId, 9_002)
    command = TestFixtures.create_command(name: "second", node_id: context.node.id)
    assert {:ok, %Accepted{}} = Biots.create(context.actor, other_id, command)

    for {biot_id, number} <- [{context.biot_id, 1}, {other_id, 2}] do
      publish(biot_id, number, context.stranger_principal)
    end

    assert {:ok, %Accepted{revision: 2}} = Biots.destroy(context.actor, context.biot_id)

    assert Repo.all(from(p in Publication, where: p.biot_id == ^context.biot_id))
           |> Enum.map(& &1.state) == [:inactive]

    refute Repo.exists?(from(g in ShellGrant, where: g.biot_id == ^context.biot_id))
    refute Repo.exists?(from(g in ViewGrant, where: g.biot_id == ^context.biot_id))

    assert Repo.all(from(p in Publication, where: p.biot_id == ^other_id))
           |> Enum.map(& &1.state) == [:active]

    assert Repo.exists?(from(g in ShellGrant, where: g.biot_id == ^other_id))
    assert Repo.exists?(from(g in ViewGrant, where: g.biot_id == ^other_id))

    assert Repo.get!(BiotRow, context.biot_id).access_revision == 2
    assert Repo.get!(BiotRow, other_id).access_revision == 1
  end

  test "a lifecycle change that is not accepted leaves the access revision alone", context do
    assert Biots.stop(context.actor, context.biot_id, 7) == {:error, {:revision_conflict, 1}}
    assert Repo.get!(BiotRow, context.biot_id).access_revision == 1

    assert {:ok, %Accepted{}} = Biots.stop(context.actor, context.biot_id, 1)
    assert Repo.get!(BiotRow, context.biot_id).access_revision == 1
  end

  test "a principal who does not own the biot cannot change it", context do
    for change <- [:start, :stop, :update_environment] do
      assert apply_change(context.stranger, context.biot_id, change, 1) == {:error, :forbidden}
    end

    assert Biots.destroy(context.stranger, context.biot_id) == {:error, :forbidden}
    assert desired(context.biot_id) == {1, :running}
  end

  test "an unauthenticated caller changes nothing", context do
    for change <- [:start, :stop, :update_environment] do
      assert apply_change(nil, context.biot_id, change, 1) == {:error, :unauthenticated}
    end

    assert Biots.destroy(nil, context.biot_id) == {:error, :unauthenticated}
    assert desired(context.biot_id) == {1, :running}
  end

  test "an unknown biot is not found", context do
    unknown = TestFixtures.id(BiotId, 9_999)

    for change <- [:start, :stop, :update_environment] do
      assert apply_change(context.actor, unknown, change, 1) == {:error, :not_found}
    end

    assert Biots.destroy(context.actor, unknown) == {:error, :not_found}
  end

  defp apply_change(actor, biot_id, :start, expected_revision) do
    Biots.start(actor, biot_id, expected_revision)
  end

  defp apply_change(actor, biot_id, :stop, expected_revision) do
    Biots.stop(actor, biot_id, expected_revision)
  end

  defp apply_change(actor, biot_id, :update_environment, expected_revision) do
    command = %SelectEnvironment{selection: TestFixtures.selection()}
    Biots.update_environment(actor, biot_id, command, expected_revision)
  end

  defp publish(biot_id, number, principal) do
    port = TestFixtures.port(3_000 + number)

    Repo.insert!(%Publication{
      biot_id: biot_id,
      port: port,
      hostname: TestFixtures.hostname(number),
      state: :active
    })

    Repo.insert!(%ViewGrant{biot_id: biot_id, port: port, principal_id: principal.id})
    Repo.insert!(%ShellGrant{biot_id: biot_id, principal_id: principal.id})
  end

  defp desired(biot_id) do
    biot = Repo.get!(BiotRow, biot_id)
    {biot.desired_revision, biot.desired_state}
  end

  defp only_operation(biot_id, target_revision) do
    Repo.one!(
      from(operation in Operation,
        where: operation.biot_id == ^biot_id and operation.target_revision == ^target_revision
      )
    )
  end

  defp operation_count(biot_id) do
    Repo.aggregate(from(operation in Operation, where: operation.biot_id == ^biot_id), :count)
  end
end
