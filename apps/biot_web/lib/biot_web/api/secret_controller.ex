defmodule BiotWeb.Api.SecretController do
  @moduledoc "Serves the runtime secret listing, delivery, and removal under `/api/biots/:id/secrets`."

  use BiotWeb, :api_controller

  alias Biot.Server.Secrets
  alias BiotWeb.Api.Json
  alias BiotWeb.Api.Response
  alias BiotWeb.Params

  def index(conn, _params) do
    with {:ok, biot_id} <- Params.biot_id(conn.path_params),
         {:ok, secrets} <- Secrets.list(actor(conn), biot_id) do
      json(conn, Enum.map(secrets, &Json.encode/1))
    end
  end

  def deliver(conn, _params) do
    with {:ok, {biot_id, name, value}} <-
           Params.secret_delivery(conn.path_params, conn.body_params),
         :ok <- Secrets.deliver(actor(conn), biot_id, name, value) do
      reply(conn, Response.build(:ok))
    end
  end

  def remove(conn, _params) do
    with {:ok, {biot_id, name}} <- Params.secret(conn.path_params),
         :ok <- Secrets.remove(actor(conn), biot_id, name) do
      reply(conn, Response.build(:ok))
    end
  end
end
