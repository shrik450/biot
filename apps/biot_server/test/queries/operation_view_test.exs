defmodule Biot.Server.Queries.OperationViewTest do
  use ExUnit.Case, async: true

  alias Biot.Protocol.Failure
  alias Biot.Protocol.OperationId
  alias Biot.Server.Queries.OperationView
  alias Biot.Server.Schema.Operation

  @operation_uuid "80000000-0000-4000-8000-000000000008"

  setup_all do
    {:ok, operation_id} = OperationId.parse(@operation_uuid)

    failure = %Failure{
      stage: :start,
      code: :container_failed,
      retry: :automatic,
      message: "container exited",
      diagnostic_ref: nil
    }

    %{operation_id: operation_id, failure: failure}
  end

  test "every kind and non-failed outcome is copied as it stands", context do
    for kind <- [:create, :start, :stop, :update_environment, :destroy],
        outcome <- [:pending, :working, :succeeded, :superseded] do
      operation = %Operation{
        id: context.operation_id,
        kind: kind,
        target_revision: 5,
        outcome: outcome,
        failure: nil
      }

      assert OperationView.project(operation) == %OperationView{
               id: context.operation_id,
               kind: kind,
               target_revision: 5,
               outcome: outcome
             }
    end
  end

  test "a failed outcome carries its failure", context do
    operation = %Operation{
      id: context.operation_id,
      kind: :start,
      target_revision: 5,
      outcome: :failed,
      failure: context.failure
    }

    assert OperationView.project(operation).outcome == {:failed, context.failure}
  end
end
