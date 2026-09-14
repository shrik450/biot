defmodule BiotWeb.Api.MeController do
  @moduledoc "Serves `GET /api/me`, the authenticated actor's principal."

  use BiotWeb, :api_controller

  alias Biot.Server.Principals
  alias BiotWeb.Api.Json

  def show(conn, _params) do
    with {:ok, principal} <- Principals.get(actor(conn)) do
      json(conn, Json.encode(principal))
    end
  end
end
