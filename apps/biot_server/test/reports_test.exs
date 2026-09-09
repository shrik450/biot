defmodule Biot.Server.ReportsTest do
  use Biot.Server.DataCase, async: false

  import Ecto.Query

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.NodeId
  alias Biot.Protocol.OrphanedAllocation
  alias Biot.Server.Biots
  alias Biot.Server.Biots.Accepted
  alias Biot.Server.Biots.SelectEnvironment
  alias Biot.Server.NodeConnections
  alias Biot.Server.Repo
  alias Biot.Server.Reports
  alias Biot.Server.Schema.AccessObservation
  alias Biot.Server.Schema.Biot, as: BiotRow
  alias Biot.Server.Schema.Environment
  alias Biot.Server.Schema.NodeObservation
  alias Biot.Server.Schema.Observation
  alias Biot.Server.Schema.Operation
  alias Biot.Server.TestFixtures

  setup do
    owner = TestFixtures.principal(1)
    node = TestFixtures.node(1)
    actor = TestFixtures.actor(owner)
    biot_id = TestFixtures.id(BiotId, 9_001)

    {:ok, %Accepted{}} =
      Biots.create(actor, biot_id, TestFixtures.create_command(node_id: node.id))

    connection_id = TestFixtures.connection_id(1)
    :ok = NodeConnections.put(node.id, %{connection_id: connection_id, state: :ready})
    on_exit(fn -> NodeConnections.delete(node.id) end)

    %{
      owner: owner,
      actor: actor,
      node: node,
      biot_id: biot_id,
      connection_id: connection_id
    }
  end

  test "a report from a node the biot is not assigned to is rejected", context do
    other_node = TestFixtures.node(2)
    report = TestFixtures.execution_report(accepted_revision: 1)

    assert Reports.observation(other_node.id, context.connection_id, context.biot_id, report) ==
             {:error, :not_assigned}

    refute Repo.exists?(from(o in Observation, where: o.biot_id == ^context.biot_id))
  end

  test "a report for an unknown biot is rejected", context do
    unknown = TestFixtures.id(BiotId, 9_999)
    report = TestFixtures.execution_report(accepted_revision: 1)

    assert Reports.observation(context.node.id, context.connection_id, unknown, report) ==
             {:error, :not_assigned}
  end

  test "the latest report replaces the previous one", context do
    first =
      TestFixtures.execution_report(accepted_revision: 1, container: :unknown, data: :unknown)

    second =
      TestFixtures.execution_report(
        accepted_revision: 1,
        container: :absent,
        data: :uninitialized
      )

    later_connection = TestFixtures.connection_id(2)

    assert {:ok, :stored} =
             Reports.observation(context.node.id, context.connection_id, context.biot_id, first)

    :ok = NodeConnections.put(context.node.id, %{connection_id: later_connection, state: :ready})

    assert {:ok, :stored} =
             Reports.observation(context.node.id, later_connection, context.biot_id, second)

    assert Repo.aggregate(Observation, :count) == 1

    observation = Repo.get!(Observation, context.biot_id)
    assert observation.connection_id == later_connection
    assert observation.container == :absent
    assert observation.data == :uninitialized
  end

  test "a report above the current desired revision is ignored and stores nothing", context do
    report = TestFixtures.execution_report(accepted_revision: 2)

    assert Reports.observation(context.node.id, context.connection_id, context.biot_id, report) ==
             {:ok, {:ignored, :revision_ahead}}

    refute Repo.exists?(from(o in Observation, where: o.biot_id == ^context.biot_id))
    assert operation(context.biot_id, 1).outcome == :pending
  end

  test "access progress never decreases within a connection and a new connection replaces it",
       context do
    assert {:ok, :stored} =
             Reports.access_applied(context.node.id, context.connection_id, context.biot_id, 3)

    assert %AccessObservation{
             connection_id: connection_id,
             applied_access_revision: 3
           } = Repo.get!(AccessObservation, context.biot_id)

    assert connection_id == context.connection_id

    for revision <- [3, 2] do
      assert Reports.access_applied(
               context.node.id,
               context.connection_id,
               context.biot_id,
               revision
             ) == {:ok, {:ignored, :revision_ahead}}

      assert Repo.get!(AccessObservation, context.biot_id).applied_access_revision == 3
    end

    replacement = TestFixtures.connection_id(2)
    :ok = NodeConnections.put(context.node.id, %{connection_id: replacement, state: :ready})

    assert {:ok, :stored} =
             Reports.access_applied(context.node.id, replacement, context.biot_id, 1)

    assert %AccessObservation{connection_id: ^replacement, applied_access_revision: 1} =
             Repo.get!(AccessObservation, context.biot_id)

    assert Reports.access_applied(context.node.id, context.connection_id, context.biot_id, 4) ==
             {:ok, {:ignored, :stale_connection}}

    assert Repo.get!(AccessObservation, context.biot_id).connection_id == replacement
  end

  test "observation ignores stale connections and stores from the current connection", context do
    stale = TestFixtures.connection_id(2)
    report = TestFixtures.execution_report()

    assert Reports.observation(context.node.id, stale, context.biot_id, report) ==
             {:ok, {:ignored, :stale_connection}}

    assert Repo.get(Observation, context.biot_id) == nil

    assert Reports.observation(
             context.node.id,
             context.connection_id,
             context.biot_id,
             report
           ) == {:ok, :stored}

    assert Repo.get!(Observation, context.biot_id).connection_id == context.connection_id
  end

  test "an execution report never changes access progress", context do
    assert {:ok, :stored} =
             Reports.access_applied(context.node.id, context.connection_id, context.biot_id, 2)

    before = Repo.get!(AccessObservation, context.biot_id)

    assert {:ok, :stored} =
             Reports.observation(
               context.node.id,
               context.connection_id,
               context.biot_id,
               TestFixtures.execution_report()
             )

    after_report = Repo.get!(AccessObservation, context.biot_id)
    assert after_report.connection_id == before.connection_id
    assert after_report.applied_access_revision == before.applied_access_revision
  end

  test "the completion evidence table decides each kind through the transaction", context do
    for kind <- [
          :create,
          :start,
          :stop,
          :update_environment_running,
          :update_environment_stopped,
          :destroy
        ] do
      arranged = arrange(context, kind)

      assert {:ok, :stored} = report(arranged, arranged.incomplete)

      assert operation(arranged.biot_id, arranged.revision).outcome == :pending,
             "#{kind} completed without full evidence"

      assert {:ok, :stored} = report(arranged, arranged.complete)

      assert operation(arranged.biot_id, arranged.revision).outcome == :succeeded,
             "#{kind} did not complete with full evidence"
    end
  end

  test "a reported failure at the operation's revision fails it", context do
    failure = TestFixtures.failure()

    reported =
      TestFixtures.execution_report(
        accepted_revision: 1,
        container: :absent,
        failure: {1, failure}
      )

    assert {:ok, :stored} =
             Reports.observation(
               context.node.id,
               context.connection_id,
               context.biot_id,
               reported
             )

    stored = operation(context.biot_id, 1)
    assert stored.outcome == :failed
    assert stored.failure == failure

    assert Repo.get!(Observation, context.biot_id).failure == {1, failure}
  end

  test "a failure tagged with another revision leaves the operation pending", context do
    assert {:ok, %Accepted{revision: 2}} = Biots.stop(context.actor, context.biot_id, 1)

    reported =
      TestFixtures.execution_report(
        accepted_revision: 2,
        container: :unknown,
        failure: {1, TestFixtures.failure()}
      )

    assert {:ok, :stored} =
             Reports.observation(
               context.node.id,
               context.connection_id,
               context.biot_id,
               reported
             )

    assert operation(context.biot_id, 2).outcome == :pending
  end

  test "a report at an older revision cannot complete newer work", context do
    environment_id = Repo.get!(BiotRow, context.biot_id).desired_environment_id
    assert {:ok, %Accepted{revision: 2}} = Biots.stop(context.actor, context.biot_id, 1)

    # Reopen the superseded create Operation so the pure decision, not the
    # supersession sweep, is what holds the historical report back.
    operation(context.biot_id, 1)
    |> Ecto.Changeset.change(outcome: :pending)
    |> Repo.update!()

    complete_for_revision_one =
      TestFixtures.execution_report(
        accepted_revision: 1,
        installed_environment_id: environment_id,
        container: TestFixtures.running_container(),
        data: :present
      )

    assert {:ok, :stored} =
             Reports.observation(
               context.node.id,
               context.connection_id,
               context.biot_id,
               complete_for_revision_one
             )

    assert operation(context.biot_id, 1).outcome == :pending
    assert operation(context.biot_id, 2).outcome == :pending

    failure = TestFixtures.failure()

    failed_at_revision_one =
      TestFixtures.execution_report(accepted_revision: 1, failure: {1, failure})

    assert {:ok, :stored} =
             Reports.observation(
               context.node.id,
               context.connection_id,
               context.biot_id,
               failed_at_revision_one
             )

    assert operation(context.biot_id, 1).outcome == :failed
    assert operation(context.biot_id, 2).outcome == :pending
  end

  test "a terminal operation keeps its outcome", context do
    environment_id = Repo.get!(BiotRow, context.biot_id).desired_environment_id
    failure = TestFixtures.failure()

    for outcome <- [:succeeded, :superseded] do
      operation(context.biot_id, 1)
      |> Ecto.Changeset.change(outcome: outcome, failure: nil)
      |> Repo.update!()

      reported =
        TestFixtures.execution_report(
          accepted_revision: 1,
          installed_environment_id: environment_id,
          container: TestFixtures.running_container(),
          failure: {1, failure}
        )

      assert {:ok, :stored} =
               Reports.observation(
                 context.node.id,
                 context.connection_id,
                 context.biot_id,
                 reported
               )

      assert operation(context.biot_id, 1).outcome == outcome
      assert operation(context.biot_id, 1).failure == nil
    end
  end

  test "a report may not claim another biot's environment", context do
    other_id = TestFixtures.id(BiotId, 9_002)
    command = TestFixtures.create_command(name: "second", node_id: context.node.id)
    assert {:ok, %Accepted{}} = Biots.create(context.actor, other_id, command)
    sibling_environment = Repo.get!(BiotRow, other_id).desired_environment_id

    reported =
      TestFixtures.execution_report(
        accepted_revision: 1,
        installed_environment_id: sibling_environment
      )

    assert Reports.observation(context.node.id, context.connection_id, context.biot_id, reported) ==
             {:error, :not_assigned}

    refute Repo.exists?(from(o in Observation, where: o.biot_id == ^context.biot_id))
  end

  test "resolution stores a manifest on an unresolved environment", context do
    environment_id = Repo.get!(BiotRow, context.biot_id).desired_environment_id
    manifest = TestFixtures.manifest()

    assert Reports.resolution(context.node.id, environment_id, manifest) == {:ok, :stored}
    assert Repo.get!(Environment, environment_id).resolution == {:resolved, manifest}

    assert Reports.resolution(context.node.id, environment_id, manifest) == {:ok, :unchanged}
    assert Repo.get!(Environment, environment_id).resolution == {:resolved, manifest}
  end

  test "a second resolution with another digest is a mismatch", context do
    environment_id = Repo.get!(BiotRow, context.biot_id).desired_environment_id
    manifest = TestFixtures.manifest()
    other_manifest = TestFixtures.manifest(revision_digit: "b")
    refute manifest.digest == other_manifest.digest

    assert Reports.resolution(context.node.id, environment_id, manifest) == {:ok, :stored}

    assert Reports.resolution(context.node.id, environment_id, other_manifest) ==
             {:error, :resolution_mismatch}

    assert Repo.get!(Environment, environment_id).resolution == {:resolved, manifest}
  end

  test "resolution rejects an environment on another node", context do
    other_node = TestFixtures.node(2)
    environment_id = Repo.get!(BiotRow, context.biot_id).desired_environment_id

    assert Reports.resolution(other_node.id, environment_id, TestFixtures.manifest()) ==
             {:error, :not_assigned}

    assert Repo.get!(Environment, environment_id).resolution == :unresolved
  end

  test "resolution rejects an unknown environment", context do
    unknown = TestFixtures.id(EnvironmentId, 8_888)

    assert Reports.resolution(context.node.id, unknown, TestFixtures.manifest()) ==
             {:error, :not_assigned}
  end

  test "a node observation upserts the connection and orphan list", context do
    orphan = %OrphanedAllocation{
      biot_id: TestFixtures.id(BiotId, 7_777),
      uid_range: %{start: 100_000, count: 65_536}
    }

    assert {:ok, %NodeObservation{}} =
             Reports.node_observation(context.node.id, context.connection_id, [orphan])

    stored = Repo.get!(NodeObservation, context.node.id)
    assert stored.connection_id == context.connection_id
    assert stored.orphaned_allocations == [orphan]

    later_connection = TestFixtures.connection_id(2)

    assert {:ok, %NodeObservation{}} =
             Reports.node_observation(context.node.id, later_connection, [])

    assert Repo.aggregate(NodeObservation, :count) == 1
    reloaded = Repo.get!(NodeObservation, context.node.id)
    assert reloaded.connection_id == later_connection
    assert reloaded.orphaned_allocations == []
  end

  test "a node observation for an unknown node is not found", context do
    unknown = TestFixtures.id(NodeId, 404)

    assert Reports.node_observation(unknown, context.connection_id, []) == {:error, :not_found}
    assert Repo.aggregate(NodeObservation, :count) == 0
  end

  defp arrange(context, :create) do
    environment_id = Repo.get!(BiotRow, context.biot_id).desired_environment_id

    %{
      node_id: context.node.id,
      connection_id: context.connection_id,
      biot_id: context.biot_id,
      revision: 1,
      complete:
        TestFixtures.execution_report(
          accepted_revision: 1,
          installed_environment_id: environment_id,
          container: TestFixtures.running_container()
        ),
      incomplete:
        TestFixtures.execution_report(
          accepted_revision: 1,
          installed_environment_id: environment_id,
          container: :absent
        )
    }
  end

  defp arrange(context, :start) do
    biot_id = fresh_biot(context, "startable")
    assert {:ok, %Accepted{revision: 2}} = Biots.stop(context.actor, biot_id, 1)
    assert {:ok, %Accepted{revision: 3}} = Biots.start(context.actor, biot_id, 2)
    environment_id = Repo.get!(BiotRow, biot_id).desired_environment_id

    %{
      node_id: context.node.id,
      connection_id: context.connection_id,
      biot_id: biot_id,
      revision: 3,
      complete:
        TestFixtures.execution_report(
          accepted_revision: 3,
          installed_environment_id: environment_id,
          container: TestFixtures.running_container()
        ),
      incomplete:
        TestFixtures.execution_report(
          accepted_revision: 3,
          installed_environment_id: nil,
          container: TestFixtures.running_container()
        )
    }
  end

  defp arrange(context, :stop) do
    biot_id = fresh_biot(context, "stoppable")
    assert {:ok, %Accepted{revision: 2}} = Biots.stop(context.actor, biot_id, 1)

    %{
      node_id: context.node.id,
      connection_id: context.connection_id,
      biot_id: biot_id,
      revision: 2,
      complete: TestFixtures.execution_report(accepted_revision: 2, container: :absent),
      incomplete:
        TestFixtures.execution_report(
          accepted_revision: 2,
          container: TestFixtures.running_container()
        )
    }
  end

  defp arrange(context, :update_environment_running) do
    biot_id = fresh_biot(context, "rebuildable")
    command = %SelectEnvironment{selection: TestFixtures.selection()}

    assert {:ok, %Accepted{revision: 2}} =
             Biots.update_environment(context.actor, biot_id, command, 1)

    environment_id = Repo.get!(BiotRow, biot_id).desired_environment_id

    %{
      node_id: context.node.id,
      connection_id: context.connection_id,
      biot_id: biot_id,
      revision: 2,
      complete:
        TestFixtures.execution_report(
          accepted_revision: 2,
          installed_environment_id: environment_id,
          container: TestFixtures.running_container()
        ),
      incomplete:
        TestFixtures.execution_report(
          accepted_revision: 2,
          installed_environment_id: environment_id,
          container: :absent
        )
    }
  end

  defp arrange(context, :update_environment_stopped) do
    biot_id = fresh_biot(context, "stopped-rebuildable")
    assert {:ok, %Accepted{revision: 2}} = Biots.stop(context.actor, biot_id, 1)
    command = %SelectEnvironment{selection: TestFixtures.selection()}

    assert {:ok, %Accepted{revision: 3}} =
             Biots.update_environment(context.actor, biot_id, command, 2)

    environment_id = Repo.get!(BiotRow, biot_id).desired_environment_id

    %{
      node_id: context.node.id,
      connection_id: context.connection_id,
      biot_id: biot_id,
      revision: 3,
      complete:
        TestFixtures.execution_report(
          accepted_revision: 3,
          installed_environment_id: environment_id,
          container: :absent
        ),
      incomplete:
        TestFixtures.execution_report(accepted_revision: 3, installed_environment_id: nil)
    }
  end

  defp arrange(context, :destroy) do
    biot_id = fresh_biot(context, "destroyable")
    assert {:ok, %Accepted{revision: 2}} = Biots.destroy(context.actor, biot_id)

    %{
      node_id: context.node.id,
      connection_id: context.connection_id,
      biot_id: biot_id,
      revision: 2,
      complete:
        TestFixtures.execution_report(
          accepted_revision: 2,
          container: :absent,
          data: :no_allocation
        ),
      incomplete:
        TestFixtures.execution_report(accepted_revision: 2, container: :absent, data: :present)
    }
  end

  defp fresh_biot(context, name) do
    number = 9_100 + :erlang.phash2(name, 800)
    biot_id = TestFixtures.id(BiotId, number)
    command = TestFixtures.create_command(name: name, node_id: context.node.id)
    assert {:ok, %Accepted{}} = Biots.create(context.actor, biot_id, command)
    biot_id
  end

  defp report(arranged, execution_report) do
    Reports.observation(
      arranged.node_id,
      arranged.connection_id,
      arranged.biot_id,
      execution_report
    )
  end

  defp operation(biot_id, target_revision) do
    Repo.one!(
      from(operation in Operation,
        where: operation.biot_id == ^biot_id and operation.target_revision == ^target_revision
      )
    )
  end
end
