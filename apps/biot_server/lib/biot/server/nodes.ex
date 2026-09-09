defmodule Biot.Server.Nodes do
  @moduledoc """
  Owns node enrollment, reloads, connection closure, and the abandonment failure.

  `reload/0` is the operator entry point for applying the enrollment file.
  """

  import Ecto.Query

  require Logger

  alias Biot.Protocol.Failure
  alias Biot.Protocol.NodeId
  alias Biot.Server.Control.Registry, as: ControlRegistry
  alias Biot.Server.Nodes.Plan
  alias Biot.Server.Nodes.RegistrationLoader
  alias Biot.Server.Repo
  alias Biot.Server.Schema.{Biot, Node, Observation, Operation}

  @type rejection ::
          Plan.rejection()
          | {:enrollment_file, RegistrationLoader.error()}
          | {:persistence_failed, NodeId.t()}

  @spec reload() :: {:ok, [Node.t()]} | {:error, rejection()}
  def reload do
    with {:ok, registrations} <- load_registrations(),
         {:ok, _nodes} = success <- commit_enrollment(registrations) do
      success
    else
      {:error, rejection} ->
        Logger.warning("node enrollment reload failed: #{message(rejection)}")
        {:error, rejection}
    end
  end

  @spec abandonment_failure() :: Failure.t()
  def abandonment_failure do
    %Failure{
      stage: :node,
      code: :node_abandoned,
      retry: :operator,
      message: "the assigned node was abandoned",
      diagnostic_ref: nil
    }
  end

  defp load_registrations do
    with {:error, error} <- RegistrationLoader.load(),
         do: {:error, {:enrollment_file, error}}
  end

  defp commit_enrollment(registrations) when is_list(registrations) do
    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.run(:plan, fn repo, _changes -> plan(repo, registrations) end)
      |> Ecto.Multi.merge(fn %{plan: plan} -> apply_actions(plan.writes) end)
      |> Ecto.Multi.run(:nodes, fn repo, _changes -> {:ok, repo.all(Node)} end)

    # Immediate mode takes SQLite write ownership before enrollment state is read.
    case Repo.transaction(multi, mode: :immediate) do
      {:ok, %{nodes: nodes, plan: plan}} ->
        close_connections(plan.close_connections)
        {:ok, nodes}

      {:error, :plan, rejection, _changes} ->
        {:error, rejection}

      {:error, action, _value, _changes} ->
        {:error, persistence_rejection(action)}
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

  defp apply_action(multi, {:replace_peer_identity, node_id, peer_identity}, now) do
    query = from(node in Node, where: node.id == ^node_id)

    Ecto.Multi.update_all(
      multi,
      {:replace_peer_identity, node_id},
      query,
      set: [peer_identity: peer_identity, updated_at: now]
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

  defp apply_action(multi, {:fail_operations, node_id}, now) do
    assigned_biot_ids = from(biot in Biot, where: biot.node_id == ^node_id, select: biot.id)

    query =
      from(operation in Operation,
        where:
          operation.biot_id in subquery(assigned_biot_ids) and
            operation.outcome in [:pending, :working]
      )

    Ecto.Multi.update_all(
      multi,
      {:fail_operations, node_id},
      query,
      set: [outcome: :failed, failure: abandonment_failure(), updated_at: now]
    )
  end

  @spec message(rejection()) :: String.t()
  def message({:persistence_failed, node_id}) do
    "node #{NodeId.to_string(node_id)} could not be saved"
  end

  def message({:enrollment_file, error}), do: RegistrationLoader.message(error)

  def message(rejection), do: Plan.message(rejection)

  defp close_connections(node_ids), do: Enum.each(node_ids, &close_connection/1)

  defp close_connection(node_id) do
    case Registry.lookup(ControlRegistry, node_id) do
      [{pid, _connection_id}] -> send(pid, :registration_changed)
      [] -> :ok
    end
  end

  defp persistence_rejection({_action, %NodeId{} = node_id}),
    do: {:persistence_failed, node_id}
end
