defmodule BiotWeb.Api.DeploymentController do
  @moduledoc "Serves `GET /api/deployment`, the settings a client needs to reach previews and SSH."

  use BiotWeb, :api_controller

  alias Biot.Server.Queries.Deployment
  alias BiotWeb.Api.Json

  def show(conn, _params) do
    with {:ok, deployment} <- Deployment.get(actor(conn)) do
      json(conn, Json.encode(deployment))
    end
  end
end
