defmodule Biot.Server.Queries.OperationView do
  @moduledoc "The user-facing projection of one lifecycle operation."

  alias Biot.Protocol.Failure
  alias Biot.Protocol.OperationId
  alias Biot.Server.Schema.Operation

  @enforce_keys [:id, :kind, :target_revision, :outcome]
  defstruct [:id, :kind, :target_revision, :outcome]

  @type outcome :: :pending | :working | :succeeded | {:failed, Failure.t()} | :superseded
  @type t :: %__MODULE__{
          id: OperationId.t(),
          kind: Operation.kind(),
          target_revision: pos_integer(),
          outcome: outcome()
        }

  @spec project(Operation.t()) :: t()
  def project(%Operation{} = operation) do
    %__MODULE__{
      id: operation.id,
      kind: operation.kind,
      target_revision: operation.target_revision,
      outcome: outcome(operation)
    }
  end

  defp outcome(%Operation{outcome: :failed, failure: failure}), do: {:failed, failure}
  defp outcome(%Operation{outcome: outcome}), do: outcome
end
