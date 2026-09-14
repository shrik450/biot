defmodule BiotWeb.Api.OperationController do
  @moduledoc "Serves `GET /api/operations/:id`, the path each accepted lifecycle change points to."

  use BiotWeb, :api_controller

  alias Biot.Server.Operations
  alias BiotWeb.Api.Json
  alias BiotWeb.Params

  def show(conn, _params) do
    with {:ok, operation_id} <- Params.operation_id(conn.path_params),
         {:ok, operation} <- Operations.get(actor(conn), operation_id) do
      json(conn, Json.encode(operation))
    end
  end
end
