defmodule Biot.Server.Nodes do
  @moduledoc "Owns the transactional import of operator-controlled node registrations."

  import Ecto.Query

  alias Biot.Protocol.NodeId
  alias Biot.Server.Nodes.Plan
  alias Biot.Server.Nodes.Registration
  alias Biot.Server.Repo
  alias Biot.Server.Schema.{Biot, Node, Observation}

  @type rejection :: Plan.rejection() | {:persistence_failed, NodeId.t()}

  @spec enroll([Registration.t()]) :: {:ok, [Node.t()]} | {:error, rejection()}
  def enroll(registrations) when is_list(registrations) do
    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.run(:plan, fn repo, _changes -> plan(repo, registrations) end)
      |> Ecto.Multi.merge(fn %{plan: actions} -> apply_actions(actions) end)
      |> Ecto.Multi.run(:nodes, fn repo, _changes -> {:ok, repo.all(Node)} end)

    # Immediate mode takes SQLite write ownership before enrollment state is read.
    case Repo.transaction(multi, mode: :immediate) do
      {:ok, %{nodes: nodes}} -> {:ok, nodes}
      {:error, :plan, rejection, _changes} -> {:error, rejection}
      {:error, action, _value, _changes} -> {:error, persistence_rejection(action)}
    end
  end

  defp plan(repo, registrations) do
    existing_nodes = repo.all(Node)

    nodes_with_allocations =
      from(biot in Biot,
        left_join: observation in Observation,
        on: observation.biot_id == biot.id,
        where: is_nil(observation.biot_id) or observation.data != :no_allocation,
        distinct: true,
        select: biot.node_id
      )
      |> repo.all()
      |> MapSet.new()

    Plan.plan(existing_nodes, registrations, nodes_with_allocations)
  end

  defp apply_actions(actions) do
    now = DateTime.utc_now()

    Enum.reduce(actions, Ecto.Multi.new(), fn action, multi ->
      apply_action(multi, action, now)
    end)
  end

  defp apply_action(multi, {:insert, registration}, _now) do
    node = %Node{
      id: registration.node_id,
      registration: registration.registration_id,
      peer_identity: registration.peer_identity,
      status: registration.status,
      max_biots: registration.max_biots
    }

    Ecto.Multi.insert(multi, {:insert, registration.node_id}, node)
  end

  defp apply_action(multi, {:update_status, node_id, status}, now) do
    query = from(node in Node, where: node.id == ^node_id)

    Ecto.Multi.update_all(
      multi,
      {:update_status, node_id},
      query,
      set: [status: status, updated_at: now]
    )
  end

  defp apply_action(multi, {:update_max_biots, node_id, max_biots}, now) do
    query = from(node in Node, where: node.id == ^node_id)

    Ecto.Multi.update_all(
      multi,
      {:update_max_biots, node_id},
      query,
      set: [max_biots: max_biots, updated_at: now]
    )
  end

  defp apply_action(multi, {:disable_omitted, node_id}, now) do
    query = from(node in Node, where: node.id == ^node_id)

    Ecto.Multi.update_all(
      multi,
      {:disable_omitted, node_id},
      query,
      set: [status: :disabled, updated_at: now]
    )
  end

  defp apply_action(multi, {:increment_access_revisions, node_id}, _now) do
    query = from(biot in Biot, where: biot.node_id == ^node_id)

    Ecto.Multi.update_all(
      multi,
      {:increment_access_revisions, node_id},
      query,
      inc: [access_revision: 1]
    )
  end

  @spec message(rejection()) :: String.t()
  def message({:persistence_failed, node_id}) do
    "node #{NodeId.to_string(node_id)} could not be saved"
  end

  def message(rejection), do: Plan.message(rejection)

  defp persistence_rejection({_action, %NodeId{} = node_id}),
    do: {:persistence_failed, node_id}
end
