defmodule Biot.Server.OperationsTest do
  use Biot.Server.DataCase, async: false

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.OperationId
  alias Biot.Server.Biots
  alias Biot.Server.Biots.Accepted
  alias Biot.Server.Operations
  alias Biot.Server.Repo
  alias Biot.Server.Schema.Operation
  alias Biot.Server.TestFixtures

  setup do
    owner = TestFixtures.principal(1)
    delegate = TestFixtures.principal(2)
    outsider = TestFixtures.principal(3)
    node = TestFixtures.node(1)
    actor = TestFixtures.actor(owner)
    biot_id = TestFixtures.id(BiotId, 9_001)

    {:ok, %Accepted{} = accepted} =
      Biots.create(actor, biot_id, TestFixtures.create_command(node_id: node.id))

    %{
      actor: actor,
      delegate: delegate,
      delegate_actor: TestFixtures.actor(delegate),
      outsider_actor: TestFixtures.actor(outsider),
      biot_id: biot_id,
      accepted: accepted
    }
  end

  test "the owner reads the operation it initiated", context do
    assert {:ok, view} = Operations.get(context.actor, context.accepted.operation_id)

    assert view.id == context.accepted.operation_id
    assert view.kind == :create
    assert view.target_revision == 1
    assert view.outcome == :pending
  end

  test "the initiating principal and the owner may both read", context do
    delegated_id = TestFixtures.operation_id(1)

    Repo.insert!(%Operation{
      id: delegated_id,
      actor_id: context.delegate.id,
      biot_id: context.biot_id,
      kind: :start,
      target_revision: 2,
      outcome: :pending,
      failure: nil
    })

    assert {:ok, view} = Operations.get(context.delegate_actor, delegated_id)
    assert view.id == delegated_id

    assert {:ok, ^view} = Operations.get(context.actor, delegated_id)
  end

  test "an unrelated principal is forbidden", context do
    assert Operations.get(context.outsider_actor, context.accepted.operation_id) ==
             {:error, :forbidden}
  end

  test "an unknown operation is not found", context do
    unknown = TestFixtures.id(OperationId, 4_242)

    assert Operations.get(context.actor, unknown) == {:error, :not_found}
  end

  test "an unauthenticated caller reads nothing", context do
    assert Operations.get(nil, context.accepted.operation_id) == {:error, :unauthenticated}
  end

  test "a failed operation carries its failure through the view", context do
    failure = TestFixtures.failure()

    Repo.get!(Operation, context.accepted.operation_id)
    |> Ecto.Changeset.change(outcome: :failed, failure: failure)
    |> Repo.update!()

    assert {:ok, view} = Operations.get(context.actor, context.accepted.operation_id)
    assert view.outcome == {:failed, failure}
  end
end
