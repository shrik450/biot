defmodule BiotWeb.Api.FetchCredentialController do
  @moduledoc """
  Serves fetch credential delivery and removal under `/api/biots/:id/fetch-credentials`.

  The source URL is in the body rather than the path, because a URL does not fit in one path
  segment.
  """

  use BiotWeb, :api_controller

  alias Biot.Server.FetchCredentials
  alias BiotWeb.Api.Response
  alias BiotWeb.Params

  def deliver(conn, _params) do
    with {:ok, {biot_id, source, value}} <-
           Params.fetch_credential_delivery(conn.path_params, conn.body_params),
         :ok <- FetchCredentials.deliver(actor(conn), biot_id, source, value) do
      reply(conn, Response.build(:ok))
    end
  end

  def remove(conn, _params) do
    with {:ok, {biot_id, source}} <- Params.fetch_credential(conn.path_params, conn.body_params),
         :ok <- FetchCredentials.remove(actor(conn), biot_id, source) do
      reply(conn, Response.build(:ok))
    end
  end
end
