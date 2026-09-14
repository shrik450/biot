defmodule BiotWeb.Api.BiotController do
  @moduledoc "Serves the Biot listing, reads, creation, and lifecycle changes under `/api/biots`."

  use BiotWeb, :api_controller

  alias Biot.Server.Biots
  alias Biot.Server.Queries.Biots, as: BiotQueries
  alias BiotWeb.Api.Json
  alias BiotWeb.Api.Response
  alias BiotWeb.Params

  def index(conn, _params) do
    with {:ok, page} <- Params.page(conn.query_params),
         {:ok, biots} <- BiotQueries.list(actor(conn), page) do
      json(conn, Enum.map(biots, &Json.encode/1))
    end
  end

  def show(conn, _params) do
    with {:ok, biot_id} <- Params.biot_id(conn.path_params),
         {:ok, biot} <- BiotQueries.get(actor(conn), biot_id) do
      json(conn, Json.encode(biot))
    end
  end

  def create(conn, _params) do
    with {:ok, {biot_id, command}} <- Params.create(conn.path_params, conn.body_params),
         {:ok, result} <- Biots.create(actor(conn), biot_id, command) do
      reply(conn, Response.build(result))
    end
  end

  def delete(conn, _params) do
    with {:ok, biot_id} <- Params.biot_id(conn.path_params),
         {:ok, result} <- Biots.destroy(actor(conn), biot_id) do
      reply(conn, Response.build(result))
    end
  end

  def start(conn, _params) do
    with {:ok, {biot_id, expected_revision}} <-
           Params.lifecycle_change(conn.path_params, conn.body_params),
         {:ok, result} <- Biots.start(actor(conn), biot_id, expected_revision) do
      reply(conn, Response.build(result))
    end
  end

  def stop(conn, _params) do
    with {:ok, {biot_id, expected_revision}} <-
           Params.lifecycle_change(conn.path_params, conn.body_params),
         {:ok, result} <- Biots.stop(actor(conn), biot_id, expected_revision) do
      reply(conn, Response.build(result))
    end
  end

  def update_environment(conn, _params) do
    with {:ok, {biot_id, selection, expected_revision}} <-
           Params.environment_change(conn.path_params, conn.body_params),
         {:ok, result} <-
           Biots.update_environment(actor(conn), biot_id, selection, expected_revision) do
      reply(conn, Response.build(result))
    end
  end
end
