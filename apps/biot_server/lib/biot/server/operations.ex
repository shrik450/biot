defmodule Biot.Server.Operations do
  @moduledoc "Owns authorized operation queries."

  alias Biot.Protocol.OperationId
  alias Biot.Server.Actor
  alias Biot.Server.CommandError
  alias Biot.Server.Queries.OperationView
  alias Biot.Server.Repo
  alias Biot.Server.Schema.{Biot, Operation}

  @spec get(Actor.t() | nil, OperationId.t()) ::
          {:ok, OperationView.t()} | {:error, CommandError.t()}
  def get(nil, %OperationId{}), do: {:error, :unauthenticated}

  def get(%Actor{} = actor, %OperationId{} = operation_id) do
    with %Operation{} = operation <- Repo.get(Operation, operation_id),
         %Biot{} = biot <- Repo.get(Biot, operation.biot_id),
         true <- authorized?(actor, operation, biot) do
      {:ok, OperationView.project(operation)}
    else
      nil -> {:error, :not_found}
      false -> {:error, :forbidden}
    end
  end

  defp authorized?(actor, operation, biot) do
    actor.principal_id == operation.actor_id or actor.principal_id == biot.owner_id
  end
end
