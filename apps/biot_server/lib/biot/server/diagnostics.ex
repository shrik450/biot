defmodule Biot.Server.Diagnostics do
  @moduledoc """
  Authorizes and retrieves bounded node-held diagnostics for lifecycle failures.

  A diagnostic belongs to one failed attempt at one Biot revision. While the node retries, that
  attempt's Failure is on the Biot's Observation; once the Operation fails, it is on the
  Operation. Either way the readers are the ones `Authorization.may_read_operation?/3` names for
  the Operation that targets that revision.

  The queries use SQLite JSON extraction because the diagnostic reference belongs to the failure
  and does not need a duplicate indexed column.
  """

  import Ecto.Query

  alias Biot.Protocol.PrivateDiagnosticId
  alias Biot.Server.Actor
  alias Biot.Server.Authorization
  alias Biot.Server.Control.Connection
  alias Biot.Server.NodeConnections
  alias Biot.Server.Principals
  alias Biot.Server.Repo
  alias Biot.Server.Schema.{Biot, Observation, Operation}

  @spec get(Actor.t() | nil, PrivateDiagnosticId.t()) ::
          {:ok, {binary(), boolean()}}
          | {:error, :unauthenticated | :not_found | :forbidden | :temporarily_unavailable}
  def get(nil, %PrivateDiagnosticId{}), do: {:error, :unauthenticated}

  def get(%Actor{} = actor, %PrivateDiagnosticId{} = diagnostic_ref) do
    with :ok <- Principals.require_enabled(Repo, actor),
         {:ok, biot} <- authorized_biot(actor, diagnostic_ref),
         {:ok, pid} <- NodeConnections.ready(biot.node_id) do
      Connection.request_diagnostic(
        pid,
        diagnostic_ref,
        Application.fetch_env!(:biot_server, :node_response_max_bytes),
        Application.fetch_env!(:biot_server, :node_request_timeout_ms)
      )
    end
  end

  defp authorized_biot(actor, diagnostic_ref) do
    diagnostic_ref = PrivateDiagnosticId.to_string(diagnostic_ref)

    rows =
      Repo.all(failed_operations(diagnostic_ref)) ++ Repo.all(failed_attempts(diagnostic_ref))

    case Enum.find(rows, fn {operation, biot} ->
           Authorization.may_read_operation?(actor, operation, biot)
         end) do
      {_operation, biot} -> {:ok, biot}
      nil when rows == [] -> {:error, :not_found}
      nil -> {:error, :forbidden}
    end
  end

  defp failed_operations(diagnostic_ref) do
    from(operation in Operation,
      join: biot in Biot,
      on: biot.id == operation.biot_id,
      where:
        fragment("json_extract(?, '$.diagnostic_ref') = ?", operation.failure, ^diagnostic_ref),
      select: {operation, biot}
    )
  end

  defp failed_attempts(diagnostic_ref) do
    from(observation in Observation,
      join: operation in Operation,
      on:
        operation.biot_id == observation.biot_id and
          operation.target_revision ==
            fragment("json_extract(?, '$.target_revision')", observation.failure),
      join: biot in Biot,
      on: biot.id == observation.biot_id,
      where:
        fragment(
          "json_extract(?, '$.failure.diagnostic_ref') = ?",
          observation.failure,
          ^diagnostic_ref
        ),
      select: {operation, biot}
    )
  end
end
