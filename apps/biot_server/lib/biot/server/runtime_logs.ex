defmodule Biot.Server.RuntimeLogs do
  @moduledoc "Authorizes and retrieves bounded service-runner output from the assigned node."

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.IncarnationId
  alias Biot.Server.Access
  alias Biot.Server.Actor
  alias Biot.Server.Authorization
  alias Biot.Server.Control.Connection
  alias Biot.Server.NodeConnections

  @spec get(Actor.t() | nil, BiotId.t()) ::
          {:ok, {IncarnationId.t(), binary(), boolean()}}
          | {:error, :unauthenticated | :not_found | :forbidden | :temporarily_unavailable}
  def get(nil, %BiotId{}), do: {:error, :unauthenticated}

  def get(%Actor{} = actor, %BiotId{} = biot_id) do
    get(actor, biot_id, Application.fetch_env!(:biot_server, :node_response_max_bytes))
  end

  @spec get(Actor.t() | nil, BiotId.t(), pos_integer()) ::
          {:ok, {IncarnationId.t(), binary(), boolean()}}
          | {:error, :unauthenticated | :not_found | :forbidden | :temporarily_unavailable}
  def get(nil, %BiotId{}, max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    {:error, :unauthenticated}
  end

  def get(%Actor{} = actor, %BiotId{} = biot_id, max_bytes)
      when is_integer(max_bytes) and max_bytes > 0 do
    with {:ok, biot, role} <- Access.fetch_readable(actor, biot_id),
         :ok <- authorize(role),
         {:ok, pid} <- NodeConnections.ready(biot.node_id) do
      Connection.request_runtime_logs(
        pid,
        biot_id,
        min(max_bytes, Application.fetch_env!(:biot_server, :node_response_max_bytes)),
        Application.fetch_env!(:biot_server, :node_request_timeout_ms)
      )
    end
  end

  defp authorize(role) do
    if Authorization.may_read_runtime_logs?(role), do: :ok, else: {:error, :forbidden}
  end
end
