defmodule BiotWeb.Api.DiagnosticController do
  @moduledoc "Serves `GET /api/diagnostics/:ref`, a failure's diagnostic from the assigned node."

  use BiotWeb, :api_controller

  alias Biot.Server.Diagnostics
  alias BiotWeb.Api.Json
  alias BiotWeb.Params

  def show(conn, _params) do
    with {:ok, diagnostic_ref} <- Params.diagnostic_ref(conn.path_params),
         {:ok, diagnostic} <- Diagnostics.get(actor(conn), diagnostic_ref) do
      json(conn, Json.diagnostic(diagnostic))
    end
  end
end
