defmodule Biot.Server.Queries.Biots do
  @moduledoc "Builds product-facing biot views for owners and collaborators."

  import Ecto.Query

  alias Biot.Protocol.BiotId
  alias Biot.Server.Access
  alias Biot.Server.Actor
  alias Biot.Server.Authorization
  alias Biot.Server.CommandError
  alias Biot.Server.NodeConnections
  alias Biot.Server.Publications
  alias Biot.Server.Queries.BiotView
  alias Biot.Server.Queries.BiotView.Input
  alias Biot.Server.Queries.PublicationView
  alias Biot.Server.Repo
  alias Biot.Server.Schema.Biot, as: BiotRow

  alias Biot.Server.Schema.{
    Node,
    Observation,
    Operation
  }

  @type page :: %{after: BiotId.t() | nil, limit: pos_integer()}

  @spec get(Actor.t() | nil, BiotId.t()) ::
          {:ok, BiotView.t()} | {:error, CommandError.t()}
  def get(nil, %BiotId{}), do: {:error, :unauthenticated}

  def get(%Actor{} = actor, %BiotId{} = biot_id) do
    with {:ok, biot, role} <- Access.fetch_readable(actor, biot_id) do
      {:ok, load_view(biot, role)}
    end
  end

  @spec list(Actor.t() | nil, page()) ::
          {:ok, [BiotView.t()]} | {:error, CommandError.t()}
  def list(nil, %{after: _after_id, limit: _limit}), do: {:error, :unauthenticated}

  def list(%Actor{} = actor, %{after: after_id, limit: limit}) do
    rows =
      BiotRow
      |> Access.readable(actor)
      |> join(:inner, [biot], node in Node, on: node.id == biot.node_id)
      |> join(:left, [biot, _node], observation in Observation,
        on: observation.biot_id == biot.id
      )
      |> after_id(after_id)
      |> order_by([biot], asc: biot.id)
      |> limit(^limit)
      |> select([biot, node, observation], {biot, node, observation})
      |> Repo.all()

    biot_ids = Enum.map(rows, fn {biot, _node, _observation} -> biot.id end)
    operations = latest_operations_for(biot_ids)
    publications = Publications.active_for(biot_ids)
    grants = Access.grants_for(actor, biot_ids)
    publication_domain = Application.fetch_env!(:biot_server, :publication_domain)

    views =
      Enum.map(rows, fn {biot, node, observation} ->
        actor_grants = Map.fetch!(grants, biot.id)

        project_view(
          biot,
          Authorization.role(actor, biot, actor_grants),
          node,
          observation,
          Map.get(operations, biot.id),
          Map.get(publications, biot.id, []),
          publication_domain
        )
      end)

    {:ok, views}
  end

  defp load_view(biot, role) do
    node = Repo.get!(Node, biot.node_id)
    observation = Repo.get(Observation, biot.id)
    operation = Map.get(latest_operations_for([biot.id]), biot.id)
    publications = Map.get(Publications.active_for([biot.id]), biot.id, [])
    publication_domain = Application.fetch_env!(:biot_server, :publication_domain)

    project_view(
      biot,
      role,
      node,
      observation,
      operation,
      publications,
      publication_domain
    )
  end

  defp project_view(
         biot,
         role,
         node,
         observation,
         operation,
         publications,
         publication_domain
       ) do
    visible_publications =
      publications
      |> PublicationView.visible(role)
      |> PublicationView.project(publication_domain)

    BiotView.project(%Input{
      biot: biot,
      role: role,
      observation: observation,
      node: node,
      operation: operation,
      connection: NodeConnections.current(node.id),
      publications: visible_publications
    })
  end

  defp latest_operations_for([]), do: %{}

  defp latest_operations_for(biot_ids) do
    target_revisions =
      from(operation in Operation,
        where: operation.biot_id in ^biot_ids,
        group_by: operation.biot_id,
        select: %{
          biot_id: operation.biot_id,
          target_revision:
            fragment(
              "COALESCE(MAX(CASE WHEN ? IN ('pending', 'working') THEN ? END), MAX(?))",
              operation.outcome,
              operation.target_revision,
              operation.target_revision
            )
        }
      )

    from(operation in Operation,
      join: target in subquery(target_revisions),
      on:
        target.biot_id == operation.biot_id and
          target.target_revision == operation.target_revision,
      select: operation
    )
    |> Repo.all()
    |> Map.new(&{&1.biot_id, &1})
  end

  defp after_id(query, nil), do: query
  defp after_id(query, %BiotId{} = biot_id), do: where(query, [biot], biot.id > ^biot_id)
end
