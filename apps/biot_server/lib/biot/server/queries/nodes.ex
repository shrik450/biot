defmodule Biot.Server.Queries.Nodes do
  @moduledoc "Builds product-facing views of all registered nodes."

  import Ecto.Query

  alias Biot.Server.Actor
  alias Biot.Server.Biots.Capacity
  alias Biot.Server.CommandError
  alias Biot.Server.NodeConnections
  alias Biot.Server.Principals
  alias Biot.Server.Queries.NodeView
  alias Biot.Server.Queries.NodeView.Input
  alias Biot.Server.Repo
  alias Biot.Server.Schema.{Node, NodeObservation}

  @spec list(Actor.t() | nil) :: {:ok, [NodeView.t()]} | {:error, CommandError.t()}
  def list(nil), do: {:error, :unauthenticated}

  def list(%Actor{} = actor) do
    with :ok <- Principals.require_enabled(Repo, actor) do
      list_views()
    end
  end

  defp list_views do
    nodes = Repo.all(from(node in Node, order_by: [asc: node.id]))
    node_ids = Enum.map(nodes, & &1.id)
    counts = Capacity.counts(Repo, node_ids)

    observations =
      from(observation in NodeObservation, where: observation.node_id in ^node_ids)
      |> Repo.all()
      |> Map.new(&{&1.node_id, &1})

    views =
      Enum.map(nodes, fn node ->
        NodeView.project(%Input{
          node: node,
          assigned_biots: Map.get(counts, node.id, 0),
          connection: NodeConnections.current(node.id),
          observation: Map.get(observations, node.id)
        })
      end)

    {:ok, views}
  end
end
