defmodule Biot.Server.Biots do
  @moduledoc "Owns biot lifecycle transactions and their product-facing queries."

  import Ecto.Query

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.BiotSpec
  alias Biot.Protocol.Desired
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.ExecutionSpec
  alias Biot.Protocol.NodeId
  alias Biot.Protocol.OperationId
  alias Biot.Server.Actor
  alias Biot.Server.Authorization
  alias Biot.Server.Biots.Accepted
  alias Biot.Server.Biots.Create
  alias Biot.Server.Biots.CreationFingerprint
  alias Biot.Server.Biots.SelectEnvironment
  alias Biot.Server.Biots.Unchanged
  alias Biot.Server.CommandError
  alias Biot.Server.NodeConnections
  alias Biot.Server.NodeWake
  alias Biot.Server.Queries.BiotView
  alias Biot.Server.Queries.BiotView.Input
  alias Biot.Server.Repo
  alias Biot.Server.Schema.Biot, as: BiotRow

  alias Biot.Server.Schema.{
    Environment,
    Node,
    Observation,
    Operation,
    Publication,
    ShellGrant
  }

  @type lifecycle_result ::
          {:ok, Accepted.t()} | {:ok, Unchanged.t()} | {:error, CommandError.t()}

  @spec create(Actor.t() | nil, BiotId.t(), Create.t()) :: lifecycle_result()
  def create(nil, %BiotId{}, %Create{}), do: {:error, :unauthenticated}

  def create(%Actor{} = actor, %BiotId{} = biot_id, %Create{} = command) do
    fingerprint = CreationFingerprint.compute(command)

    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.run(:plan, fn repo, _changes ->
        plan_creation(repo, actor, biot_id, command, fingerprint)
      end)
      |> Ecto.Multi.merge(&creation_writes/1)

    multi
    |> Repo.transaction(mode: :immediate)
    |> lifecycle_transaction_result()
  end

  @spec start(Actor.t() | nil, BiotId.t(), pos_integer()) :: lifecycle_result()
  def start(actor, biot_id, expected_revision) do
    lifecycle_change(actor, biot_id, expected_revision, :start, nil)
  end

  @spec stop(Actor.t() | nil, BiotId.t(), pos_integer()) :: lifecycle_result()
  def stop(actor, biot_id, expected_revision) do
    lifecycle_change(actor, biot_id, expected_revision, :stop, nil)
  end

  @spec update_environment(
          Actor.t() | nil,
          BiotId.t(),
          SelectEnvironment.t(),
          pos_integer()
        ) :: lifecycle_result()
  def update_environment(
        actor,
        biot_id,
        %SelectEnvironment{selection: selection},
        expected_revision
      ) do
    environment_id = generate_id(EnvironmentId)

    lifecycle_change(
      actor,
      biot_id,
      expected_revision,
      {:update_environment, environment_id},
      selection
    )
  end

  @spec destroy(Actor.t() | nil, BiotId.t()) :: lifecycle_result()
  def destroy(nil, %BiotId{}), do: {:error, :unauthenticated}

  def destroy(%Actor{} = actor, %BiotId{} = biot_id) do
    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.run(:plan, fn repo, _changes ->
        plan_destroy(repo, actor, biot_id)
      end)
      |> Ecto.Multi.merge(&lifecycle_writes/1)

    multi
    |> Repo.transaction(mode: :immediate)
    |> lifecycle_transaction_result()
  end

  @spec get(Actor.t() | nil, BiotId.t()) :: {:ok, BiotView.t()} | {:error, CommandError.t()}
  def get(nil, %BiotId{}), do: {:error, :unauthenticated}

  def get(%Actor{} = actor, %BiotId{} = biot_id) do
    with %BiotRow{} = biot <- Repo.get(BiotRow, biot_id),
         true <- Authorization.owner?(actor, biot) do
      {:ok, load_view(biot)}
    else
      nil -> {:error, :not_found}
      false -> {:error, :forbidden}
    end
  end

  @spec list(Actor.t() | nil, %{after: BiotId.t() | nil, limit: pos_integer()}) ::
          {:ok, [BiotView.t()]} | {:error, CommandError.t()}
  def list(nil, %{after: _after_id, limit: _limit}), do: {:error, :unauthenticated}

  def list(%Actor{} = actor, %{after: after_id, limit: limit})
      when is_integer(limit) and limit > 0 do
    rows =
      BiotRow
      |> where([biot], biot.owner_id == ^actor.principal_id)
      |> after_id(after_id)
      |> order_by([biot], asc: biot.id)
      |> limit(^limit)
      |> join(:inner, [biot], node in Node, on: node.id == biot.node_id)
      |> join(:left, [biot, _node], observation in Observation,
        on: observation.biot_id == biot.id
      )
      |> select([biot, node, observation], {biot, node, observation})
      |> Repo.all()

    operations = latest_operations(rows)

    views =
      Enum.map(rows, fn {biot, node, observation} ->
        project_view(biot, node, observation, Map.get(operations, biot.id))
      end)

    {:ok, views}
  end

  @spec spec(BiotId.t()) :: {:ok, BiotSpec.t()} | {:error, :not_found}
  def spec(%BiotId{} = biot_id) do
    with %BiotRow{} = biot <- Repo.get(BiotRow, biot_id),
         %Environment{} = environment <- Repo.get(Environment, biot.desired_environment_id) do
      {:ok,
       %BiotSpec{
         execution: %ExecutionSpec{
           biot_id: biot.id,
           repository: biot.repository,
           desired: BiotRow.desired(biot),
           environment: %{id: environment.id, selection: environment.selection}
         },
         access_revision: biot.access_revision
       }}
    else
      nil -> {:error, :not_found}
    end
  end

  defp plan_creation(repo, actor, biot_id, command, fingerprint) do
    case repo.get(BiotRow, biot_id) do
      nil -> plan_new_creation(repo, actor, biot_id, command, fingerprint)
      biot -> plan_creation_retry(repo, actor, biot, fingerprint)
    end
  end

  defp plan_creation_retry(repo, actor, biot, fingerprint) do
    if Authorization.owner?(actor, biot) and biot.creation_fingerprint == fingerprint do
      {:ok, {:unchanged, current_lifecycle_result(repo, biot)}}
    else
      {:error, :creation_conflict}
    end
  end

  defp plan_new_creation(repo, actor, biot_id, command, fingerprint) do
    with {:ok, node_id} <- requested_node_id(command.node_id),
         {:ok, node} <- available_node(repo, node_id),
         :ok <- require_capacity(repo, node),
         :ok <- require_name_available(repo, actor.principal_id, command.name) do
      environment_id = generate_id(EnvironmentId)
      operation_id = generate_id(OperationId)

      biot = %BiotRow{
        id: biot_id,
        name: command.name,
        owner_id: actor.principal_id,
        node_id: node.id,
        repository: command.repository,
        creation_fingerprint: fingerprint,
        desired_revision: 1,
        desired_state: :running,
        desired_environment_id: environment_id,
        access_revision: 1
      }

      environment = %Environment{
        id: environment_id,
        biot_id: biot.id,
        selection: command.environment,
        resolution: :unresolved
      }

      operation = operation(operation_id, actor.principal_id, biot.id, :create, 1)
      {:ok, {:create, biot, environment, operation}}
    end
  end

  defp creation_writes(%{plan: {:unchanged, result}}) do
    Ecto.Multi.new()
    |> Ecto.Multi.put(:result, result)
    |> Ecto.Multi.put(:wake, nil)
  end

  defp creation_writes(%{plan: {:create, biot, environment, operation}}) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:biot, creation_changeset(biot))
    |> Ecto.Multi.insert(:environment, environment)
    |> Ecto.Multi.insert(:operation, operation)
    |> Ecto.Multi.put(:result, accepted(operation))
    |> Ecto.Multi.put(:wake, {biot.node_id, biot.id})
  end

  defp lifecycle_change(nil, %BiotId{}, _expected_revision, _change, _selection),
    do: {:error, :unauthenticated}

  defp lifecycle_change(
         %Actor{} = actor,
         %BiotId{} = biot_id,
         expected_revision,
         change,
         selection
       ) do
    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.run(:plan, fn repo, _changes ->
        plan_lifecycle_change(repo, actor, biot_id, expected_revision, change, selection)
      end)
      |> Ecto.Multi.merge(&lifecycle_writes/1)

    multi
    |> Repo.transaction(mode: :immediate)
    |> lifecycle_transaction_result()
  end

  defp plan_lifecycle_change(
         repo,
         actor,
         biot_id,
         expected_revision,
         change,
         selection
       ) do
    with {:ok, biot} <- load_controlled_biot(repo, actor, biot_id),
         :ok <- check_revision(biot, expected_revision) do
      transition(biot, actor.principal_id, change, selection)
    end
  end

  defp plan_destroy(repo, actor, biot_id) do
    with {:ok, biot} <- load_controlled_biot(repo, actor, biot_id) do
      transition(biot, actor.principal_id, :destroy, nil)
    end
  end

  defp transition(biot, actor_id, change, selection) do
    case Desired.transition(BiotRow.desired(biot), change) do
      {:changed, desired} ->
        kind = operation_kind(change)
        operation = operation(generate_id(OperationId), actor_id, biot.id, kind, desired.revision)
        {:ok, {:change, biot, desired, selection, operation}}

      :unchanged ->
        {:ok, {:unchanged, %Unchanged{biot_id: biot.id, revision: biot.desired_revision}}}

      {:error, :destroyed} ->
        {:error, :destroyed}
    end
  end

  defp lifecycle_writes(%{plan: {:unchanged, result}}) do
    Ecto.Multi.new()
    |> Ecto.Multi.put(:result, result)
    |> Ecto.Multi.put(:wake, nil)
  end

  defp lifecycle_writes(%{plan: {:change, biot, desired, selection, operation}}) do
    Ecto.Multi.new()
    |> maybe_insert_environment(biot.id, desired.environment_id, selection)
    |> maybe_delete_access(biot.id, operation.kind)
    |> Ecto.Multi.update(:biot, desired_changeset(biot, desired, operation.kind))
    |> Ecto.Multi.insert(:operation, operation)
    |> Ecto.Multi.update_all(
      :supersede_operations,
      from(existing in Operation,
        where:
          existing.biot_id == ^biot.id and existing.target_revision < ^desired.revision and
            existing.outcome in [:pending, :working]
      ),
      set: [outcome: :superseded]
    )
    |> Ecto.Multi.put(:result, accepted(operation))
    |> Ecto.Multi.put(:wake, {biot.node_id, biot.id})
  end

  defp maybe_insert_environment(multi, _biot_id, _environment_id, nil), do: multi

  defp maybe_insert_environment(multi, biot_id, environment_id, selection) do
    environment = %Environment{
      id: environment_id,
      biot_id: biot_id,
      selection: selection,
      resolution: :unresolved
    }

    Ecto.Multi.insert(multi, :environment, environment)
  end

  defp maybe_delete_access(multi, biot_id, :destroy) do
    multi
    |> Ecto.Multi.delete_all(
      :publications,
      from(publication in Publication, where: publication.biot_id == ^biot_id)
    )
    |> Ecto.Multi.delete_all(
      :shell_grants,
      from(grant in ShellGrant, where: grant.biot_id == ^biot_id)
    )
  end

  defp maybe_delete_access(multi, _biot_id, _kind), do: multi

  defp desired_changeset(biot, desired, :destroy) do
    Ecto.Changeset.change(biot,
      desired_revision: desired.revision,
      desired_state: desired.state,
      desired_environment_id: desired.environment_id,
      access_revision: biot.access_revision + 1
    )
  end

  defp desired_changeset(biot, desired, _kind) do
    Ecto.Changeset.change(biot,
      desired_revision: desired.revision,
      desired_state: desired.state,
      desired_environment_id: desired.environment_id
    )
  end

  defp load_controlled_biot(repo, actor, biot_id) do
    case repo.get(BiotRow, biot_id) do
      nil -> {:error, :not_found}
      biot -> authorize_lifecycle(actor, biot)
    end
  end

  defp authorize_lifecycle(actor, biot) do
    if Authorization.may_control_lifecycle?(actor, biot),
      do: {:ok, biot},
      else: {:error, :forbidden}
  end

  defp check_revision(%BiotRow{desired_revision: revision}, revision), do: :ok

  defp check_revision(%BiotRow{desired_revision: current_revision}, _expected_revision),
    do: {:error, {:revision_conflict, current_revision}}

  defp requested_node_id(:default) do
    case Application.get_env(:biot_server, :default_node_id) do
      %NodeId{} = node_id -> {:ok, node_id}
      nil -> {:error, {:invalid_input, %{node_id: [:no_default_node]}}}
    end
  end

  defp requested_node_id(%NodeId{} = node_id), do: {:ok, node_id}

  defp available_node(repo, node_id) do
    case repo.get(Node, node_id) do
      nil -> {:error, :not_found}
      %Node{status: :enabled} = node -> {:ok, node}
      %Node{} -> {:error, :node_disabled}
    end
  end

  defp require_capacity(repo, node) do
    allocated =
      from(biot in BiotRow,
        left_join: observation in Observation,
        on: observation.biot_id == biot.id,
        where:
          biot.node_id == ^node.id and
            (biot.desired_state != :destroyed or is_nil(observation.biot_id) or
               observation.data != :no_allocation),
        select: count(biot.id)
      )
      |> repo.one()

    if allocated < node.max_biots, do: :ok, else: {:error, :capacity_exceeded}
  end

  defp require_name_available(repo, owner_id, name) do
    exists? =
      repo.exists?(
        from(biot in BiotRow,
          where:
            biot.owner_id == ^owner_id and biot.name == ^name and
              biot.desired_state != :destroyed
        )
      )

    if exists?, do: {:error, :name_conflict}, else: :ok
  end

  defp current_lifecycle_result(repo, biot) do
    case current_nonterminal_operation(repo, biot.id) do
      nil -> %Unchanged{biot_id: biot.id, revision: biot.desired_revision}
      operation -> accepted(operation)
    end
  end

  defp current_nonterminal_operation(repo, biot_id) do
    from(operation in Operation,
      where: operation.biot_id == ^biot_id and operation.outcome in [:pending, :working],
      order_by: [desc: operation.target_revision],
      limit: 1
    )
    |> repo.one()
  end

  defp operation(operation_id, actor_id, biot_id, kind, target_revision) do
    %Operation{
      id: operation_id,
      actor_id: actor_id,
      biot_id: biot_id,
      kind: kind,
      target_revision: target_revision,
      outcome: :pending,
      failure: nil
    }
  end

  defp accepted(operation) do
    %Accepted{
      operation_id: operation.id,
      biot_id: operation.biot_id,
      revision: operation.target_revision
    }
  end

  defp lifecycle_transaction_result({:ok, %{result: result, wake: wake}}) do
    wake_node(wake)
    {:ok, result}
  end

  defp lifecycle_transaction_result({:error, :plan, error, _changes}), do: {:error, error}

  defp lifecycle_transaction_result({:error, :biot, %Ecto.Changeset{} = changeset, _changes}) do
    if name_conflict?(changeset) do
      {:error, :name_conflict}
    else
      raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
    end
  end

  defp wake_node(nil), do: :ok

  defp wake_node({node_id, biot_id}), do: NodeWake.spec_changed(node_id, biot_id)

  defp after_id(query, nil), do: query
  defp after_id(query, %BiotId{} = biot_id), do: where(query, [biot], biot.id > ^biot_id)

  defp load_view(biot) do
    node = Repo.get!(Node, biot.node_id)
    observation = Repo.get(Observation, biot.id)
    operation = latest_operation(biot.id)

    project_view(biot, node, observation, operation)
  end

  defp latest_operation(biot_id) do
    current_nonterminal_operation(Repo, biot_id) ||
      Repo.one(
        from(operation in Operation,
          where: operation.biot_id == ^biot_id,
          order_by: [desc: operation.target_revision],
          limit: 1
        )
      )
  end

  defp latest_operations(rows) do
    biot_ids = Enum.map(rows, fn {biot, _node, _observation} -> biot.id end)
    latest_operations_for(biot_ids)
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

  defp project_view(biot, node, observation, operation) do
    BiotView.project(%Input{
      biot: biot,
      observation: observation,
      node: node,
      operation: operation,
      connection: NodeConnections.current(node.id),
      publications: [],
      direct_secrets_ever_delivered: false
    })
  end

  defp operation_kind(:start), do: :start
  defp operation_kind(:stop), do: :stop
  defp operation_kind({:update_environment, %EnvironmentId{}}), do: :update_environment
  defp operation_kind(:destroy), do: :destroy

  defp creation_changeset(biot) do
    biot
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:name, name: :live_biot_name)
  end

  defp name_conflict?(changeset) do
    Enum.any?(changeset.errors, fn
      {:name, {_message, metadata}} ->
        metadata[:constraint] == :unique and metadata[:constraint_name] == "live_biot_name"

      _error ->
        false
    end)
  end

  defp generate_id(module) do
    {:ok, id} = module.parse(Ecto.UUID.generate())
    id
  end
end
