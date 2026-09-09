defmodule Biot.Server.Reports do
  @moduledoc "Stores authenticated node reports and advances lifecycle operation outcomes."

  import Ecto.Query

  require Logger

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.ConnectionId
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.ExecutionReport
  alias Biot.Protocol.Manifest
  alias Biot.Protocol.NodeId
  alias Biot.Server.NodeConnections
  alias Biot.Server.Operations.Completion
  alias Biot.Server.Repo

  alias Biot.Server.Schema.{
    AccessObservation,
    Biot,
    Environment,
    Node,
    NodeObservation,
    Observation,
    Operation
  }

  @type ingestion_error ::
          :not_assigned | :not_found | :resolution_mismatch | :temporarily_unavailable
  @type ignore_reason :: :revision_ahead | :stale_connection
  @type ignored :: {:ignored, ignore_reason()}

  @spec observation(
          NodeId.t(),
          ConnectionId.t(),
          BiotId.t(),
          ExecutionReport.t()
        ) :: {:ok, :stored | ignored()} | {:error, ingestion_error()}
  def observation(
        %NodeId{} = node_id,
        %ConnectionId{} = connection_id,
        %BiotId{} = biot_id,
        %ExecutionReport{} = report
      ) do
    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.run(:plan, fn repo, _changes ->
        plan_observation(repo, node_id, connection_id, biot_id, report)
      end)
      |> Ecto.Multi.merge(&observation_writes/1)

    case Repo.transaction(multi, mode: :immediate) do
      {:ok, %{result: result}} -> {:ok, result}
      {:error, :plan, error, _changes} -> {:error, error}
    end
  end

  @spec access_applied(NodeId.t(), ConnectionId.t(), BiotId.t(), pos_integer()) ::
          {:ok, :stored | ignored()} | {:error, ingestion_error()}
  def access_applied(
        %NodeId{} = node_id,
        %ConnectionId{} = connection_id,
        %BiotId{} = biot_id,
        revision
      ) do
    case Repo.transaction(
           fn -> access_progress(Repo, node_id, connection_id, biot_id, revision) end,
           mode: :immediate
         ) do
      {:ok, result} -> {:ok, result}
      {:error, error} -> {:error, error}
    end
  end

  @spec resolution(NodeId.t(), EnvironmentId.t(), Manifest.t()) ::
          {:ok, :stored | :unchanged} | {:error, ingestion_error()}
  def resolution(%NodeId{} = node_id, %EnvironmentId{} = environment_id, %Manifest{} = manifest) do
    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.run(:plan, fn repo, _changes ->
        plan_resolution(repo, node_id, environment_id, manifest)
      end)
      |> Ecto.Multi.merge(&resolution_writes/1)

    case Repo.transaction(multi, mode: :immediate) do
      {:ok, %{result: result}} ->
        {:ok, result}

      {:error, :plan, :resolution_mismatch, _changes} ->
        Logger.error("environment resolution mismatch",
          node_id: NodeId.to_string(node_id),
          environment_id: EnvironmentId.to_string(environment_id)
        )

        {:error, :resolution_mismatch}

      {:error, :plan, error, _changes} ->
        {:error, error}
    end
  end

  @spec node_observation(NodeId.t(), ConnectionId.t(), list()) ::
          {:ok, NodeObservation.t()} | {:error, :not_found | :temporarily_unavailable}
  def node_observation(
        %NodeId{} = node_id,
        %ConnectionId{} = connection_id,
        orphaned_allocations
      )
      when is_list(orphaned_allocations) do
    now = DateTime.utc_now()

    with %Node{} <- Repo.get(Node, node_id),
         {:ok, observation} <-
           upsert_node_observation(node_id, connection_id, orphaned_allocations, now) do
      Logger.info("node observation received",
        node_id: NodeId.to_string(node_id),
        connection_id: ConnectionId.to_string(connection_id),
        received_at: DateTime.to_iso8601(now),
        orphaned_allocations: orphaned_allocations
      )

      {:ok, observation}
    else
      nil -> {:error, :not_found}
      {:error, _changeset} -> {:error, :temporarily_unavailable}
    end
  end

  defp plan_observation(repo, node_id, connection_id, biot_id, report) do
    with {:ok, %Biot{} = biot} <-
           report_biot(repo, node_id, connection_id, biot_id),
         :ok <- check_environment(repo, biot, report.installed_environment_id) do
      plan_assigned_observation(repo, biot, connection_id, report)
    else
      {:ok, {:ignored, _reason} = ignored} -> {:ok, ignored}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_environment(_repo, _biot, nil), do: :ok

  defp check_environment(repo, %Biot{id: biot_id}, environment_id) do
    if repo.exists?(
         from(environment in Environment,
           where: environment.id == ^environment_id and environment.biot_id == ^biot_id
         )
       ) do
      :ok
    else
      {:error, :not_assigned}
    end
  end

  defp plan_assigned_observation(_repo, biot, _connection_id, report)
       when report.accepted_revision > biot.desired_revision,
       do: {:ok, {:ignored, :revision_ahead}}

  defp plan_assigned_observation(repo, biot, connection_id, report) do
    observation = %Observation{
      biot_id: biot.id,
      connection_id: connection_id,
      received_at: DateTime.utc_now(),
      accepted_revision: report.accepted_revision,
      installed_environment_id: report.installed_environment_id,
      container: report.container,
      data: report.data,
      failure: report.failure
    }

    operation =
      repo.get_by(Operation,
        biot_id: biot.id,
        target_revision: report.accepted_revision
      )

    outcome = operation_outcome(operation, biot, report)
    {:ok, {:store, observation, operation, outcome}}
  end

  defp observation_writes(%{plan: {:ignored, _reason} = ignored}) do
    Ecto.Multi.new() |> Ecto.Multi.put(:result, ignored)
  end

  defp observation_writes(%{plan: {:store, observation, operation, outcome}}) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:observation, observation,
      on_conflict: {:replace, observation_fields()},
      conflict_target: :biot_id
    )
    |> maybe_update_operation(operation, outcome)
    |> Ecto.Multi.put(:result, :stored)
  end

  defp maybe_update_operation(multi, %Operation{} = operation, :succeeded) do
    Ecto.Multi.update(
      multi,
      :operation,
      Ecto.Changeset.change(operation, outcome: :succeeded, failure: nil)
    )
  end

  defp maybe_update_operation(multi, %Operation{} = operation, {:failed, failure}) do
    Ecto.Multi.update(
      multi,
      :operation,
      Ecto.Changeset.change(operation, outcome: :failed, failure: failure)
    )
  end

  defp maybe_update_operation(multi, _operation, :pending), do: multi
  defp maybe_update_operation(multi, _operation, :no_change), do: multi

  defp operation_outcome(%Operation{outcome: outcome}, _biot, _report)
       when outcome in [:succeeded, :failed, :superseded],
       do: :no_change

  defp operation_outcome(%Operation{} = operation, biot, report) do
    Completion.decide(operation.kind, operation.target_revision, Biot.desired(biot), report)
  end

  defp operation_outcome(nil, _biot, _report), do: :no_change

  defp observation_fields do
    [
      :connection_id,
      :received_at,
      :accepted_revision,
      :installed_environment_id,
      :container,
      :data,
      :failure,
      :updated_at
    ]
  end

  defp access_progress(
         repo,
         node_id,
         connection_id,
         biot_id,
         revision
       ) do
    case report_biot(repo, node_id, connection_id, biot_id) do
      {:ok, %Biot{} = biot} ->
        access_observation = repo.get(AccessObservation, biot.id)

        case plan_progress(access_observation, biot, connection_id, revision) do
          {:ignored, _reason} = ignored ->
            ignored

          {:store, access_observation} ->
            repo.insert!(access_observation,
              on_conflict: {:replace, access_observation_fields()},
              conflict_target: :biot_id
            )

            :stored
        end

      {:ok, {:ignored, _reason} = ignored} ->
        ignored

      {:error, reason} ->
        repo.rollback(reason)
    end
  end

  defp plan_progress(
         %AccessObservation{
           connection_id: connection_id,
           applied_access_revision: applied_revision
         },
         %Biot{},
         connection_id,
         revision
       )
       when revision <= applied_revision,
       do: {:ignored, :revision_ahead}

  defp plan_progress(_access_observation, %Biot{} = biot, connection_id, revision) do
    {:store,
     %AccessObservation{
       biot_id: biot.id,
       connection_id: connection_id,
       applied_access_revision: revision
     }}
  end

  defp access_observation_fields do
    [:connection_id, :applied_access_revision, :updated_at]
  end

  defp report_biot(repo, node_id, connection_id, biot_id) do
    case repo.get(Biot, biot_id) do
      %Biot{node_id: ^node_id} = biot ->
        if NodeConnections.current?(connection_id, NodeConnections.current(node_id)),
          do: {:ok, biot},
          else: {:ok, {:ignored, :stale_connection}}

      %Biot{} ->
        {:error, :not_assigned}

      nil ->
        {:error, :not_assigned}
    end
  end

  defp plan_resolution(repo, node_id, environment_id, manifest) do
    environment =
      repo.one(
        from(environment in Environment,
          join: biot in Biot,
          on: biot.id == environment.biot_id,
          where: environment.id == ^environment_id and biot.node_id == ^node_id,
          select: environment
        )
      )

    case environment do
      nil ->
        {:error, :not_assigned}

      %Environment{resolution: :unresolved} ->
        {:ok, {:store, environment, manifest}}

      %Environment{resolution: {:resolved, %{digest: digest}}} when digest == manifest.digest ->
        {:ok, :unchanged}

      %Environment{} ->
        {:error, :resolution_mismatch}
    end
  end

  defp resolution_writes(%{plan: :unchanged}) do
    Ecto.Multi.new() |> Ecto.Multi.put(:result, :unchanged)
  end

  defp resolution_writes(%{plan: {:store, environment, manifest}}) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(
      :environment,
      Ecto.Changeset.change(environment, resolution: {:resolved, manifest})
    )
    |> Ecto.Multi.put(:result, :stored)
  end

  defp upsert_node_observation(node_id, connection_id, orphaned_allocations, received_at) do
    %NodeObservation{
      node_id: node_id,
      connection_id: connection_id,
      received_at: received_at,
      orphaned_allocations: orphaned_allocations
    }
    |> Repo.insert(
      on_conflict: {:replace, [:connection_id, :received_at, :orphaned_allocations, :updated_at]},
      conflict_target: :node_id,
      returning: true
    )
  end
end
