defmodule BiotWeb.Api.GrantController do
  @moduledoc "Serves the grant list and the shell and view grant changes under `/api/biots/:id/grants`."

  use BiotWeb, :api_controller

  alias Biot.Server.Access
  alias Biot.Server.Queries.AccessDisplayView
  alias BiotWeb.Api.Json
  alias BiotWeb.Api.Response
  alias BiotWeb.Params

  def index(conn, _params) do
    with {:ok, biot_id} <- Params.biot_id(conn.path_params),
         {:ok, grants} <- AccessDisplayView.get(actor(conn), biot_id) do
      json(conn, Json.encode(grants))
    end
  end

  def grant_shell(conn, _params) do
    with {:ok, {biot_id, principal_id}} <- Params.shell_grant(conn.path_params),
         {:ok, result} <- Access.grant_shell(actor(conn), biot_id, principal_id) do
      reply(conn, Response.build(result))
    end
  end

  def revoke_shell(conn, _params) do
    with {:ok, {biot_id, principal_id}} <- Params.shell_grant(conn.path_params),
         {:ok, result} <- Access.revoke_shell(actor(conn), biot_id, principal_id) do
      reply(conn, Response.build(result))
    end
  end

  def grant_view(conn, _params) do
    with {:ok, {biot_id, port, principal_id}} <- Params.view_grant(conn.path_params),
         {:ok, result} <- Access.grant_view(actor(conn), biot_id, port, principal_id) do
      reply(conn, Response.build(result))
    end
  end

  def revoke_view(conn, _params) do
    with {:ok, {biot_id, port, principal_id}} <- Params.view_grant(conn.path_params),
         {:ok, result} <- Access.revoke_view(actor(conn), biot_id, port, principal_id) do
      reply(conn, Response.build(result))
    end
  end
end
