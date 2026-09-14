defmodule BiotWeb.Api.PublicationController do
  @moduledoc "Serves discovery, publishing, and unpublishing under `/api/biots/:id/publications`."

  use BiotWeb, :api_controller

  alias Biot.Server.Publications
  alias BiotWeb.Api.Json
  alias BiotWeb.Api.Response
  alias BiotWeb.Params

  def index(conn, _params) do
    with {:ok, biot_id} <- Params.biot_id(conn.path_params),
         {:ok, publications} <- Publications.discover(actor(conn), biot_id) do
      json(conn, Enum.map(publications, &Json.encode/1))
    end
  end

  def publish(conn, _params) do
    with {:ok, {biot_id, port}} <- Params.publication(conn.path_params),
         {:ok, result} <- Publications.publish(actor(conn), biot_id, port) do
      reply(conn, Response.build(result))
    end
  end

  def unpublish(conn, _params) do
    with {:ok, {biot_id, port}} <- Params.publication(conn.path_params),
         {:ok, result} <- Publications.unpublish(actor(conn), biot_id, port) do
      reply(conn, Response.build(result))
    end
  end
end
