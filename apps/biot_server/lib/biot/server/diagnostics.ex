defmodule Biot.Server.Diagnostics do
  @moduledoc """
  Authorizes and retrieves bounded node-held diagnostics for lifecycle failures.

  The query uses SQLite JSON extraction because the diagnostic reference belongs to the failure and does not need a duplicate indexed column.
  """

  import Ecto.Query

  alias Biot.Protocol.PrivateDiagnosticId
  alias Biot.Server.Actor
  alias Biot.Server.Control.Connection
  alias Biot.Server.Control.Registry, as: ControlRegistry
  alias Biot.Server.NodeConnections
  alias Biot.Server.Repo
  alias Biot.Server.Schema.{Biot, Operation}

  @spec get(Actor.t() | nil, PrivateDiagnosticId.t()) ::
          {:ok, {binary(), boolean()}}
          | {:error, :unauthenticated | :not_found | :forbidden | :temporarily_unavailable}
  def get(nil, %PrivateDiagnosticId{}), do: {:error, :unauthenticated}

  def get(%Actor{} = actor, %PrivateDiagnosticId{} = diagnostic_ref) do
    with {:ok, biot} <- authorized_biot(actor, diagnostic_ref),
         %{connection_id: connection_id, state: :ready} <- NodeConnections.current(biot.node_id),
         [{pid, ^connection_id}] <- Registry.lookup(ControlRegistry, biot.node_id) do
      Connection.request_diagnostic(
        pid,
        diagnostic_ref,
        Application.fetch_env!(:biot_server, :diagnostic_max_bytes),
        Application.fetch_env!(:biot_server, :diagnostic_timeout_ms)
      )
    else
      nil -> {:error, :temporarily_unavailable}
      %{state: :synchronizing} -> {:error, :temporarily_unavailable}
      [] -> {:error, :temporarily_unavailable}
      [{_pid, _connection_id}] -> {:error, :temporarily_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorized_biot(actor, diagnostic_ref) do
    diagnostic_ref = PrivateDiagnosticId.to_string(diagnostic_ref)

    # Authorize through the Operation failure because it carries the diagnostic ref and the initiating actor.
    rows =
      from(operation in Operation,
        join: biot in Biot,
        on: biot.id == operation.biot_id,
        where:
          fragment(
            "json_extract(?, '$.diagnostic_ref') = ?",
            operation.failure,
            ^diagnostic_ref
          ),
        select: {operation, biot}
      )
      |> Repo.all()

    case Enum.find(rows, &authorized?(actor, &1)) do
      {_operation, biot} -> {:ok, biot}
      nil when rows == [] -> {:error, :not_found}
      nil -> {:error, :forbidden}
    end
  end

  defp authorized?(actor, {operation, biot}) do
    actor.principal_id in [operation.actor_id, biot.owner_id]
  end
end
