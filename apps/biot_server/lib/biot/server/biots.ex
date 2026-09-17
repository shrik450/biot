defmodule Biot.Server.Biots do
  @moduledoc "Owns Biot lifecycle transactions."

  import Ecto.Query

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.Desired
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.NodeId
  alias Biot.Protocol.OperationId
  alias Biot.Server.Access
  alias Biot.Server.Actor
  alias Biot.Server.Authorization
  alias Biot.Server.Biots.Accepted
  alias Biot.Server.Biots.Capacity
  alias Biot.Server.Biots.Create
  alias Biot.Server.Biots.CreationFingerprint
  alias Biot.Server.Biots.SelectEnvironment
  alias Biot.Server.Biots.Unchanged
  alias Biot.Server.CommandError
  alias Biot.Server.CommitEffects
  alias Biot.Server.Nodes
  alias Biot.Server.Nodes.Status
  alias Biot.Server.Principals
  alias Biot.Server.Publications
  alias Biot.Server.Repo
  alias Biot.Server.Schema.Biot, as: BiotRow

  alias Biot.Server.Schema.{
    Environment,
    Node,
    Operation
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
    |> after_commit()
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
    environment_id = EnvironmentId.generate()

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
    |> after_commit()
  end

  defp plan_creation(repo, actor, biot_id, command, fingerprint) do
    # A disabled owner must not replay an existing create.
    with :ok <- Principals.require_enabled(repo, actor) do
      case repo.get(BiotRow, biot_id) do
        nil -> plan_new_creation(repo, actor, biot_id, command, fingerprint)
        biot -> plan_creation_retry(repo, actor, biot, fingerprint)
      end
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
      environment_id = EnvironmentId.generate()
      operation_id = OperationId.generate()

      biot = %BiotRow{
        id: biot_id,
        name: command.name,
        owner_id: actor.principal_id,
        node_id: node.id,
        repository: command.repository,
        creation_fingerprint: fingerprint,
        desired_revision: 1,
        desired_state: command.initial_state,
        desired_environment_id: environment_id,
        access_revision: 1,
        direct_secret_exposure_possible: false
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
    |> Ecto.Multi.put(:owners, [])
    |> Ecto.Multi.put(:wakes, [])
    |> Ecto.Multi.put(:readers, [])
  end

  defp creation_writes(%{plan: {:create, biot, environment, operation}}) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:biot, creation_changeset(biot))
    |> Ecto.Multi.insert(:environment, environment)
    |> Ecto.Multi.insert(:operation, operation)
    |> Ecto.Multi.put(:result, accepted(operation))
    |> Ecto.Multi.put(:owners, [])
    |> Ecto.Multi.put(:wakes, [{biot.node_id, biot.id}])
    |> Ecto.Multi.put(:readers, [biot.id])
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
    |> after_commit()
  end

  defp plan_lifecycle_change(
         repo,
         actor,
         biot_id,
         expected_revision,
         change,
         selection
       ) do
    with :ok <- Principals.require_enabled(repo, actor),
         {:ok, biot} <- load_controlled_biot(repo, actor, biot_id),
         node = repo.get!(Node, biot.node_id),
         :ok <- require_lifecycle_capable_node(node),
         :ok <- check_revision(biot, expected_revision) do
      transition(biot, node, actor.principal_id, change, selection)
    end
  end

  defp plan_destroy(repo, actor, biot_id) do
    with :ok <- Principals.require_enabled(repo, actor),
         {:ok, biot} <- load_controlled_biot(repo, actor, biot_id) do
      node = repo.get!(Node, biot.node_id)
      transition(biot, node, actor.principal_id, :destroy, nil)
    end
  end

  defp transition(biot, node, actor_id, change, selection) do
    case Desired.transition(BiotRow.desired(biot), change) do
      {:changed, desired} ->
        kind = operation_kind(change)

        operation =
          OperationId.generate()
          |> operation(actor_id, biot.id, kind, desired.revision)
          |> fail_for_abandoned_node(node)

        {:ok, {:change, biot, node, desired, selection, operation}}

      :unchanged ->
        {:ok, {:unchanged, %Unchanged{biot_id: biot.id, revision: biot.desired_revision}}}

      {:error, :destroyed} ->
        {:error, :destroyed}
    end
  end

  defp lifecycle_writes(%{plan: {:unchanged, result}}) do
    Ecto.Multi.new()
    |> Ecto.Multi.put(:result, result)
    |> Ecto.Multi.put(:owners, [])
    |> Ecto.Multi.put(:wakes, [])
    |> Ecto.Multi.put(:readers, [])
  end

  defp lifecycle_writes(%{plan: {:change, biot, node, desired, selection, operation}}) do
    Ecto.Multi.new()
    |> maybe_insert_environment(biot.id, desired.environment_id, selection)
    |> withdraw_access(biot.id, operation.kind)
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
    |> Ecto.Multi.put(:wakes, lifecycle_wake(biot, node))
    |> Ecto.Multi.put(:readers, [biot.id])
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

  defp withdraw_access(multi, biot_id, :destroy) do
    multi
    |> Publications.withdraw_all(biot_id)
    |> Access.revoke_shell_grants(biot_id)
    |> Ecto.Multi.put(:owners, [{:biot, biot_id}])
  end

  defp withdraw_access(multi, _biot_id, kind)
       when kind in [:start, :stop, :update_environment],
       do: Ecto.Multi.put(multi, :owners, [])

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

  defp require_lifecycle_capable_node(%Node{} = node),
    do: Status.accepts_lifecycle_change(node.status)

  defp check_revision(%BiotRow{desired_revision: revision}, revision), do: :ok

  defp check_revision(%BiotRow{desired_revision: current_revision}, _expected_revision),
    do: {:error, {:revision_conflict, current_revision}}

  defp requested_node_id(:default) do
    case Application.get_env(:biot_server, :default_node_id) do
      %NodeId{} = node_id -> {:ok, node_id}
      nil -> CommandError.invalid_input(%{node_id: [:no_default_node]})
    end
  end

  defp requested_node_id(%NodeId{} = node_id), do: {:ok, node_id}

  defp available_node(repo, node_id) do
    case repo.get(Node, node_id) do
      nil -> {:error, :not_found}
      %Node{} = node -> with :ok <- Status.accepts_new_biots(node.status), do: {:ok, node}
    end
  end

  defp require_capacity(repo, node) do
    if Capacity.room?(repo, node), do: :ok, else: {:error, :capacity_exceeded}
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

  defp fail_for_abandoned_node(%Operation{kind: :destroy} = operation, %Node{} = node) do
    if Status.written_off?(node.status),
      do: %{operation | outcome: :failed, failure: Nodes.abandonment_failure()},
      else: operation
  end

  defp fail_for_abandoned_node(%Operation{} = operation, %Node{}), do: operation

  defp lifecycle_wake(biot, %Node{} = node) do
    if Status.written_off?(node.status), do: [], else: [{biot.node_id, biot.id}]
  end

  defp accepted(operation) do
    %Accepted{
      operation_id: operation.id,
      biot_id: operation.biot_id,
      revision: operation.target_revision
    }
  end

  defp after_commit({:ok, %{result: result, owners: owners, wakes: wakes, readers: readers}}) do
    CommitEffects.enforce(%CommitEffects{owners: owners, wakes: wakes, readers: readers})
    {:ok, result}
  end

  defp after_commit({:error, :plan, error, _changes}), do: {:error, error}

  defp after_commit({:error, :biot, %Ecto.Changeset{} = changeset, _changes}) do
    if name_conflict?(changeset) do
      {:error, :name_conflict}
    else
      raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
    end
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
end
