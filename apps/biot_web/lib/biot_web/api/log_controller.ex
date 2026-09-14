defmodule BiotWeb.Api.LogController do
  @moduledoc "Serves `GET /api/biots/:id/logs`, the tail of a Biot's service output from its node."

  use BiotWeb, :api_controller

  alias Biot.Server.RuntimeLogs
  alias BiotWeb.Api.Json
  alias BiotWeb.Params

  def show(conn, _params) do
    with {:ok, {biot_id, max_bytes}} <- Params.runtime_logs(conn.path_params, conn.query_params),
         {:ok, logs} <- RuntimeLogs.get(actor(conn), biot_id, max_bytes) do
      json(conn, Json.runtime_logs(logs))
    end
  end
end
