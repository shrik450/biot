defmodule Biot.Server.EctoTypesTest do
  use Biot.Server.DataCase, async: false

  alias Biot.Protocol.IncarnationId
  alias Biot.Server.Repo
  alias Biot.Server.Schema.Environment
  alias Biot.Server.Schema.Observation
  alias Biot.Server.Schema.Operation
  alias Biot.Server.TestFixtures

  test "observation container, data, and failure variants round-trip through rows" do
    owner = TestFixtures.principal(1)
    node = TestFixtures.node(1)
    failure = TestFixtures.failure()

    cases = [
      {:unknown_no_allocation, :unknown, :no_allocation, nil},
      {:absent_unknown, :absent, :unknown, {1, failure}},
      {:running_uninitialized, {:present, TestFixtures.id(IncarnationId, 1), :running},
       :uninitialized, nil},
      {:exited_present, {:present, TestFixtures.id(IncarnationId, 2), {:exited, 17}}, :present,
       {2, failure}},
      {:unknown_lost, :unknown, :lost, nil}
    ]

    for {{label, container, data, observation_failure}, number} <-
          Enum.with_index(cases, 1) do
      {biot, _environment} = TestFixtures.biot(owner, node, number)

      TestFixtures.observation(biot, number,
        container: container,
        data: data,
        failure: observation_failure
      )

      loaded = Repo.get!(Observation, biot.id)
      assert loaded.container == container, "container case #{label}"
      assert loaded.data == data, "data case #{label}"
      assert loaded.failure == observation_failure, "failure case #{label}"
    end
  end

  test "environment selection and both resolution variants round-trip through rows" do
    owner = TestFixtures.principal(1)
    node = TestFixtures.node(1)
    selection = TestFixtures.selection()
    manifest = TestFixtures.manifest()

    {_first_biot, unresolved} =
      TestFixtures.biot(owner, node, 1, selection: selection, resolution: :unresolved)

    {_second_biot, resolved} =
      TestFixtures.biot(owner, node, 2,
        selection: selection,
        resolution: {:resolved, manifest}
      )

    assert Repo.get!(Environment, unresolved.id).selection == selection
    assert Repo.get!(Environment, unresolved.id).resolution == :unresolved
    assert Repo.get!(Environment, resolved.id).selection == selection
    assert Repo.get!(Environment, resolved.id).resolution == {:resolved, manifest}
  end

  test "a failed operation and its Failure payload round-trip through a row" do
    owner = TestFixtures.principal(1)
    node = TestFixtures.node(1)
    {biot, _environment} = TestFixtures.biot(owner, node, 1)
    failure = TestFixtures.failure()

    operation =
      Repo.insert!(%Operation{
        id: TestFixtures.operation_id(1),
        actor_id: owner.id,
        biot_id: biot.id,
        kind: :start,
        target_revision: 1,
        outcome: :failed,
        failure: failure
      })

    loaded = Repo.get!(Operation, operation.id)
    assert loaded.outcome == :failed
    assert loaded.failure == failure
  end

  test "loading a corrupt stored custom value raises" do
    owner = TestFixtures.principal(1)
    node = TestFixtures.node(1)
    {biot, _environment} = TestFixtures.biot(owner, node, 1)
    TestFixtures.observation(biot, 1, container: :unknown)

    Repo.query!(
      "UPDATE observations SET container = ? WHERE biot_id = ?",
      [Jason.encode!(%{"state" => "present"}), to_string(biot.id)]
    )

    assert_raise ArgumentError, ~r/stored .* value is corrupt/, fn ->
      Repo.get!(Observation, biot.id)
    end
  end
end
