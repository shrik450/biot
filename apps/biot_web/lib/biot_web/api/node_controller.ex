defmodule BiotWeb.Api.NodeController do
  @moduledoc "Serves `GET /api/nodes`, every registered node with its capacity and orphans."

  use BiotWeb, :api_controller

  alias Biot.Server.Queries.Nodes
  alias BiotWeb.Api.Json

  def index(conn, _params) do
    with {:ok, nodes} <- Nodes.list(actor(conn)) do
      json(conn, Enum.map(nodes, &Json.encode/1))
    end
  end
end
