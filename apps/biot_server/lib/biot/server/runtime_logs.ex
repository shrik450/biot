defmodule Biot.Server.RuntimeLogs do
  @moduledoc "Authorizes and retrieves bounded service-runner output from the assigned node."

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.IncarnationId
  alias Biot.Server.Access
  alias Biot.Server.Actor
  alias Biot.Server.Authorization
  alias Biot.Server.Control.Connection
  alias Biot.Server.NodeConnections

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

  @spec authorize(Authorization.role()) :: :ok | {:error, :forbidden}
  defp authorize(:owner), do: :ok
  defp authorize({:collaborator, %{shell: true}}), do: :ok
  defp authorize({:collaborator, %{shell: false}}), do: {:error, :forbidden}
end
