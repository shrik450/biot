defmodule BiotWeb.Api.PrincipalController do
  @moduledoc "Serves `GET /api/principals?email=`, which finds the principal to name in a grant."

  use BiotWeb, :api_controller

  alias Biot.Server.Principals
  alias BiotWeb.Api.Json
  alias BiotWeb.Params

  def resolve(conn, _params) do
    with {:ok, email} <- Params.principal_email(conn.query_params),
         {:ok, principal_id} <- Principals.resolve_email(actor(conn), email) do
      json(conn, Json.principal_id(principal_id))
    end
  end
end
