defmodule Biot.Node.Journal do
  @moduledoc "Owns node-local SQLite records and their domain values."

  import Ecto.Query

  alias Biot.Node.Allocation
  alias Biot.Node.ArtifactId
  alias Biot.Node.Installation
  alias Biot.Node.Journal.Schema.Allocation, as: AllocationRow
  alias Biot.Node.Journal.Schema.Diagnostic, as: DiagnosticRow
  alias Biot.Node.Journal.Schema.Installation, as: InstallationRow
  alias Biot.Node.Journal.Schema.LocalIntent, as: LocalIntentRow
  alias Biot.Node.Journal.Schema.Resolution, as: ResolutionRow
  alias Biot.Node.Journal.Schema.RetryState, as: RetryStateRow
  alias Biot.Node.LocalIntent
  alias Biot.Node.Repo
  alias Biot.Node.Resolution
  alias Biot.Node.RetryState
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.BiotSpec
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.ExecutionReport
  alias Biot.Protocol.Failure
  alias Biot.Protocol.Manifest
  alias Biot.Protocol.PrivateDiagnosticId
  alias Biot.Protocol.RepositorySource

  @spec allocation(BiotId.t()) :: Allocation.t() | nil
  def allocation(%BiotId{} = biot_id) do
    case Repo.get(AllocationRow, biot_id) do
      nil -> nil
      row -> allocation_value(row)
    end
  end

  @spec allocations() :: [Allocation.t()]
  def allocations do
    AllocationRow |> Repo.all() |> Enum.map(&allocation_value/1)
  end

  @spec next_uid_start(non_neg_integer(), pos_integer(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, :uid_ranges_exhausted}
  def next_uid_start(base, count, limit) do
    used = AllocationRow |> select([row], row.uid_start) |> Repo.all() |> MapSet.new()

    base
    |> Stream.iterate(&(&1 + count))
    |> Enum.take_while(&(&1 + count <= limit))
    |> Enum.find(&(not MapSet.member?(used, &1)))
    |> case do
      nil -> {:error, :uid_ranges_exhausted}
      start -> {:ok, start}
    end
  end

  @spec put_allocation(Allocation.t()) :: {:ok, Allocation.t()} | {:error, term()}
  def put_allocation(%Allocation{} = allocation) do
    allocation
    |> allocation_row()
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:uid_start, name: :allocation_uid_start)
    |> Repo.insert()
    |> case do
      {:ok, row} -> {:ok, allocation_value(row)}
      {:error, changeset} -> allocation_insert_error(changeset)
    end
  end

  @spec complete_initialization(Allocation.t()) :: {:ok, Allocation.t()} | {:error, term()}
  def complete_initialization(%Allocation{} = allocation) do
    Repo.transaction(fn -> set_initialized(allocation, true) end, mode: :immediate)
  end

  @spec reset_initialization(Allocation.t()) :: :ok | {:error, term()}
  def reset_initialization(%Allocation{} = allocation) do
    Repo.transaction(
      fn ->
        _allocation = set_initialized(allocation, false)
        :ok
      end,
      mode: :immediate
    )
    |> transaction_value()
  end

  defp set_initialized(allocation, initialized) do
    allocation
    |> current_allocation!()
    |> Ecto.Changeset.change(initialized: initialized)
    |> Repo.update!()
    |> allocation_value()
  end

  @spec installation(BiotId.t()) :: Installation.t() | nil
  def installation(%BiotId{} = biot_id) do
    case Repo.get(InstallationRow, biot_id) do
      nil -> nil
      row -> installation_value(row)
    end
  end

  @spec put_installation(Allocation.t(), EnvironmentId.t(), ArtifactId.t()) ::
          {:ok, Installation.t()} | {:error, term()}
  def put_installation(%Allocation{} = allocation, environment_id, artifact_id) do
    Repo.transaction(
      fn -> upsert_installation(allocation.biot_id, environment_id, artifact_id) end,
      mode: :immediate
    )
  end

  @spec resolution(BiotId.t(), EnvironmentId.t()) :: Resolution.t() | nil
  def resolution(%BiotId{} = biot_id, %EnvironmentId{} = environment_id) do
    case Repo.get_by(ResolutionRow, biot_id: biot_id, environment_id: environment_id) do
      nil -> nil
      row -> resolution_value(row)
    end
  end

  @spec resolution_owner(EnvironmentId.t()) :: BiotId.t() | nil
  def resolution_owner(%EnvironmentId{} = environment_id) do
    case Repo.get(ResolutionRow, environment_id) do
      nil -> nil
      row -> row.biot_id
    end
  end

  @spec resolutions(BiotId.t()) :: [Resolution.t()]
  def resolutions(%BiotId{} = biot_id) do
    ResolutionRow
    |> where([row], row.biot_id == ^biot_id)
    |> Repo.all()
    |> Enum.map(&resolution_value/1)
  end

  @spec put_resolution(BiotId.t(), EnvironmentId.t(), Manifest.t()) ::
          {:ok, Resolution.t()} | {:error, term()}
  def put_resolution(biot_id, environment_id, manifest) do
    Repo.transaction(
      fn ->
        case Repo.get(ResolutionRow, environment_id) do
          nil -> insert_resolution(biot_id, environment_id, manifest)
          %ResolutionRow{biot_id: ^biot_id} = row -> resolution_value(row)
          %ResolutionRow{} -> Repo.rollback(:ownership_mismatch)
        end
      end,
      mode: :immediate
    )
  end

  @spec delete_environment(BiotId.t(), EnvironmentId.t()) :: :ok | {:error, term()}
  def delete_environment(biot_id, environment_id) do
    Repo.transaction(
      fn ->
        case Repo.get_by(ResolutionRow, biot_id: biot_id, environment_id: environment_id) do
          nil -> :ok
          row -> delete_environment_records(row)
        end
      end,
      mode: :immediate
    )
    |> transaction_value()
  end

  defp delete_environment_records(resolution) do
    case Repo.get(InstallationRow, resolution.biot_id) do
      %InstallationRow{environment_id: environment_id} = installation
      when environment_id == resolution.environment_id ->
        Repo.delete!(installation)

      _other ->
        :ok
    end

    Repo.delete!(resolution)
    :ok
  end

  @spec delete_allocation(Allocation.t()) :: :ok | {:error, term()}
  def delete_allocation(%Allocation{} = allocation) do
    Repo.transaction(
      fn ->
        case Repo.get(AllocationRow, allocation.biot_id) do
          nil -> :ok
          row -> delete_current_allocation(row, allocation)
        end
      end,
      mode: :immediate
    )
    |> transaction_value()
  end

  defp delete_current_allocation(row, allocation) do
    cond do
      Allocation.resources(allocation_value(row)) != Allocation.resources(allocation) ->
        Repo.rollback(:stale)

      allocation_records_remain?(allocation.biot_id) ->
        Repo.rollback(:records_remain)

      true ->
        Repo.delete!(row)
        :ok
    end
  end

  @doc """
  Stores one biot's desired intent, and drops the retry record of the revision it replaces.
  """
  @spec put_intent(BiotSpec.t()) :: {:ok, LocalIntent.t()} | {:error, :invalid_intent}
  def put_intent(%BiotSpec{} = spec) do
    Repo.transaction(fn -> accept_intent(spec) end, mode: :immediate)
    |> case do
      {:ok, row} -> {:ok, intent_value(row)}
      {:error, _reason} -> {:error, :invalid_intent}
    end
  end

  @doc """
  Replaces every local intent with the synchronized set. A biot the server no longer sends intent
  for loses its row, which stops its controller and leaves its allocation to be reported as an
  orphan. Its retry budget and any destruction receipt go with that row.
  """
  @spec replace_intents([BiotSpec.t()]) :: {:ok, [BiotId.t()]} | {:error, term()}
  def replace_intents(specs) when is_list(specs) do
    Repo.transaction(
      fn ->
        Enum.each(specs, fn spec -> _row = accept_intent(spec) end)
        synchronized = Enum.map(specs, & &1.execution.biot_id)

        {_count, removed} =
          LocalIntentRow
          |> where([row], row.biot_id not in ^synchronized)
          |> select([row], row.biot_id)
          |> Repo.delete_all()

        RetryStateRow
        |> where([row], row.biot_id not in ^synchronized)
        |> Repo.delete_all()

        removed
      end,
      mode: :immediate
    )
  end

  @doc "Indexes a diagnostic and returns file IDs that the committed index no longer names."
  @spec index_diagnostic(
          PrivateDiagnosticId.t(),
          BiotId.t(),
          pos_integer(),
          Failure.stage(),
          boolean(),
          pos_integer()
        ) :: {:ok, [PrivateDiagnosticId.t()]} | {:error, term()}
  def index_diagnostic(
        %PrivateDiagnosticId{} = diagnostic_id,
        %BiotId{} = biot_id,
        revision,
        stage,
        truncated,
        max_entries
      ) do
    Repo.transaction(
      fn ->
        previous =
          Repo.get_by(DiagnosticRow,
            biot_id: biot_id,
            revision: revision,
            stage: Atom.to_string(stage)
          )

        sequence = next_diagnostic_sequence(biot_id)
        upsert_diagnostic(diagnostic_id, biot_id, revision, stage, truncated, sequence)
        evicted = evict_diagnostics(biot_id, max_entries)

        [previous && previous.diagnostic_id | evicted]
        |> Enum.reject(&(is_nil(&1) or &1 == diagnostic_id))
        |> Enum.uniq()
      end,
      mode: :immediate
    )
  end

  @spec diagnostic(PrivateDiagnosticId.t()) :: boolean() | nil
  def diagnostic(%PrivateDiagnosticId{} = diagnostic_id) do
    case Repo.get(DiagnosticRow, diagnostic_id) do
      nil -> nil
      row -> row.truncated
    end
  end

  @doc "Deletes one Biot's diagnostic index and returns the files that belonged to it."
  @spec forget_diagnostics(BiotId.t()) ::
          {:ok, [PrivateDiagnosticId.t()]} | {:error, term()}
  def forget_diagnostics(%BiotId{} = biot_id) do
    Repo.transaction(
      fn ->
        ids =
          DiagnosticRow
          |> where([row], row.biot_id == ^biot_id)
          |> select([row], row.diagnostic_id)
          |> Repo.all()

        DiagnosticRow
        |> where([row], row.biot_id == ^biot_id)
        |> Repo.delete_all()

        ids
      end,
      mode: :immediate
    )
  end

  @doc """
  Stores the final report of a destruction this node finished, and drops the biot's retry record.
  The controller exits after this write, and the control connection replays the report until the
  server stops sending intent.

  The intent row stays behind as the receipt, so the retry record has to be deleted on its own.
  """
  @spec put_destruction_report(BiotId.t(), ExecutionReport.t()) ::
          {:ok, LocalIntent.t()} | {:error, term()}
  def put_destruction_report(%BiotId{} = biot_id, %ExecutionReport{} = report) do
    Repo.transaction(
      fn ->
        case Repo.get(LocalIntentRow, biot_id) do
          nil ->
            Repo.rollback(:no_intent)

          row ->
            delete_retry_state(biot_id)

            row
            |> Ecto.Changeset.change(destruction_report: report)
            |> Repo.update!()
            |> intent_value()
        end
      end,
      mode: :immediate
    )
  end

  @spec intent(BiotId.t()) :: LocalIntent.t() | nil
  def intent(%BiotId{} = biot_id) do
    case Repo.get(LocalIntentRow, biot_id) do
      nil -> nil
      row -> intent_value(row)
    end
  end

  @spec intents() :: [LocalIntent.t()]
  def intents do
    LocalIntentRow |> Repo.all() |> Enum.map(&intent_value/1)
  end

  @doc "What one biot has already spent, for whichever desired revision the row records."
  @spec retry_state(BiotId.t()) :: RetryState.t() | nil
  def retry_state(%BiotId{} = biot_id) do
    case Repo.get(RetryStateRow, biot_id) do
      nil -> nil
      row -> retry_state_value(row)
    end
  end

  @typedoc """
  The answer to every retry write. `:superseded` means the intent row no longer holds the revision
  the caller asked to write for, so the write changed nothing.
  """
  @type retry_write :: {:ok, RetryState.t()} | :superseded

  @doc """
  Counts one more attempt at `stage` and clears the pending backoff. The controller calls this
  before it starts the action, so an attempt that a crash interrupts still costs the budget.
  """
  @spec record_attempt(BiotId.t(), pos_integer(), Failure.stage()) :: retry_write()
  def record_attempt(%BiotId{} = biot_id, revision, stage) do
    update_retry_state(biot_id, revision, &RetryState.count_attempt(&1, stage))
  end

  @doc "Records the failure of the attempt just made, and when the next automatic attempt is due."
  @spec record_failure(BiotId.t(), pos_integer(), Failure.t(), DateTime.t() | nil) ::
          retry_write()
  def record_failure(%BiotId{} = biot_id, revision, %Failure{} = failure, next_attempt_at) do
    update_retry_state(
      biot_id,
      revision,
      &%{&1 | failure: failure, next_attempt_at: next_attempt_at}
    )
  end

  @doc """
  Drops the recorded failure after an action succeeded. The attempts stay, so work that keeps
  failing and recovering still runs out of budget.
  """
  @spec clear_failure(BiotId.t(), pos_integer()) :: retry_write()
  def clear_failure(%BiotId{} = biot_id, revision) do
    update_retry_state(biot_id, revision, &%{&1 | failure: nil, next_attempt_at: nil})
  end

  @doc """
  Records that this revision is waiting for a credential for `source`, and gives back the attempt
  the action that found this out had already spent on `stage`.

  Giving the attempt back is one half of the model's "waiting consumes no retry budget"; the other
  half is `Biot.Node.Reconcile`, which runs no action while the wait stands. Those are the only two
  places that know it.
  """
  @spec record_waiting_for(BiotId.t(), pos_integer(), Failure.stage(), RepositorySource.t()) ::
          retry_write()
  def record_waiting_for(%BiotId{} = biot_id, revision, stage, %RepositorySource{} = source) do
    update_retry_state(biot_id, revision, &RetryState.wait_for_credential(&1, stage, source))
  end

  @doc "Ends the wait once the credential arrives, so the next convergence runs the fetch again."
  @spec clear_waiting_for(BiotId.t(), pos_integer()) :: retry_write()
  def clear_waiting_for(%BiotId{} = biot_id, revision) do
    update_retry_state(biot_id, revision, &%{&1 | waiting_for: nil})
  end

  # Invariant: a retry row always describes the revision the intent row holds. Reading the intent
  # row inside the write's own transaction is what keeps that true while a controller is still
  # working on a revision the server has already replaced.
  defp update_retry_state(biot_id, revision, change) do
    Repo.transaction(
      fn ->
        if desired_revision(biot_id) == revision do
          biot_id
          |> retry_state()
          |> RetryState.for_revision(biot_id, revision)
          |> change.()
          |> upsert_retry_state()
        else
          Repo.rollback(:superseded)
        end
      end,
      mode: :immediate
    )
    |> case do
      {:ok, %RetryState{} = state} -> {:ok, state}
      {:error, :superseded} -> :superseded
    end
  end

  defp desired_revision(biot_id) do
    case Repo.get(LocalIntentRow, biot_id) do
      nil -> nil
      row -> row.biot_spec.execution.desired.revision
    end
  end

  defp upsert_retry_state(%RetryState{} = state) do
    now = DateTime.utc_now()

    changes = [
      target_revision: state.target_revision,
      attempts: state.attempts,
      next_attempt_at: state.next_attempt_at,
      waiting_for: state.waiting_for,
      failure: state.failure
    ]

    %RetryStateRow{}
    |> Ecto.Changeset.change([{:biot_id, state.biot_id} | changes])
    |> Repo.insert!(
      on_conflict: [set: [{:updated_at, now} | changes]],
      conflict_target: :biot_id,
      returning: true
    )
    |> retry_state_value()
  end

  # Each new or replacement row gets the next per-Biot sequence, so retention has one total order.
  defp next_diagnostic_sequence(biot_id) do
    latest =
      DiagnosticRow
      |> where([row], row.biot_id == ^biot_id)
      |> select([row], max(row.sequence))
      |> Repo.one()

    (latest || 0) + 1
  end

  defp upsert_diagnostic(
         diagnostic_id,
         biot_id,
         revision,
         stage,
         truncated,
         sequence
       ) do
    changes = [
      diagnostic_id: diagnostic_id,
      truncated: truncated,
      sequence: sequence
    ]

    %DiagnosticRow{}
    |> Ecto.Changeset.change(
      diagnostic_id: diagnostic_id,
      biot_id: biot_id,
      revision: revision,
      stage: Atom.to_string(stage),
      truncated: truncated,
      sequence: sequence
    )
    |> Repo.insert!(
      on_conflict: [set: changes],
      conflict_target: [:biot_id, :revision, :stage]
    )
  end

  defp evict_diagnostics(biot_id, max_entries) do
    ids =
      DiagnosticRow
      |> where([row], row.biot_id == ^biot_id)
      |> order_by([row], desc: row.sequence)
      |> select([row], row.diagnostic_id)
      |> Repo.all()
      |> Enum.drop(max_entries)

    DiagnosticRow
    |> where([row], row.diagnostic_id in ^ids)
    |> Repo.delete_all()

    ids
  end

  defp drop_superseded_retry_state(biot_id, revision) do
    RetryStateRow
    |> where([row], row.biot_id == ^biot_id and row.target_revision != ^revision)
    |> Repo.delete_all()

    :ok
  end

  defp delete_retry_state(biot_id) do
    RetryStateRow |> where([row], row.biot_id == ^biot_id) |> Repo.delete_all()
    :ok
  end

  # A retry record describes one desired revision. Dropping the superseded record here, in the
  # transaction that stores the new revision, is what keeps a crash before the controller reads the
  # new intent from spending a budget the server already replaced.
  defp accept_intent(%BiotSpec{} = spec) do
    :ok = drop_superseded_retry_state(spec.execution.biot_id, spec.execution.desired.revision)

    case upsert_intent(spec) do
      {:ok, row} -> row
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # The conflict sets only the spec, so newer intent for a biot whose destruction the node already
  # finished keeps the receipt the server has not acknowledged yet.
  defp upsert_intent(%BiotSpec{} = spec) do
    now = DateTime.utc_now()

    %LocalIntentRow{}
    |> Ecto.Changeset.change(biot_id: spec.execution.biot_id, biot_spec: spec)
    |> Repo.insert(
      on_conflict: [set: [biot_spec: spec, updated_at: now]],
      conflict_target: :biot_id,
      returning: true
    )
  end

  defp intent_value(row) do
    %LocalIntent{
      biot_id: row.biot_id,
      biot_spec: row.biot_spec,
      destruction_report: row.destruction_report
    }
  end

  defp retry_state_value(row) do
    %RetryState{
      biot_id: row.biot_id,
      target_revision: row.target_revision,
      attempts: row.attempts,
      next_attempt_at: row.next_attempt_at,
      waiting_for: row.waiting_for,
      failure: row.failure
    }
  end

  defp allocation_row(allocation) do
    %AllocationRow{
      biot_id: allocation.biot_id,
      uid_start: allocation.uid_range.start,
      uid_count: allocation.uid_range.count,
      data_root: allocation.data_root,
      network_id: allocation.network_id,
      initialized: initialized?(allocation.initialization)
    }
  end

  defp allocation_value(row) do
    %Allocation{
      biot_id: row.biot_id,
      uid_range: %{start: row.uid_start, count: row.uid_count},
      data_root: row.data_root,
      network_id: row.network_id,
      initialization: initialization(row.initialized)
    }
  end

  defp installation_value(row) do
    %Installation{
      biot_id: row.biot_id,
      environment_id: row.environment_id,
      artifact_id: row.artifact_id
    }
  end

  defp resolution_value(row) do
    %Resolution{
      environment_id: row.environment_id,
      manifest: row.manifest,
      snapshot_path: row.snapshot_path
    }
  end

  defp current_allocation!(allocation) do
    case Repo.get(AllocationRow, allocation.biot_id) do
      nil ->
        Repo.rollback(:stale)

      row ->
        if Allocation.resources(allocation_value(row)) == Allocation.resources(allocation),
          do: row,
          else: Repo.rollback(:stale)
    end
  end

  defp upsert_installation(biot_id, environment_id, artifact_id) do
    now = DateTime.utc_now()

    %InstallationRow{}
    |> Ecto.Changeset.change(
      biot_id: biot_id,
      environment_id: environment_id,
      artifact_id: artifact_id
    )
    |> Repo.insert!(
      on_conflict: [
        set: [environment_id: environment_id, artifact_id: artifact_id, updated_at: now]
      ],
      conflict_target: :biot_id,
      returning: true
    )
    |> installation_value()
  end

  defp insert_resolution(biot_id, environment_id, manifest) do
    %ResolutionRow{}
    |> Ecto.Changeset.change(
      environment_id: environment_id,
      biot_id: biot_id,
      manifest: manifest,
      snapshot_path: nil
    )
    |> Repo.insert!()
    |> resolution_value()
  end

  defp allocation_insert_error(changeset) do
    if uid_start_conflict?(changeset),
      do: {:error, :uid_start_conflict},
      else: {:error, changeset}
  end

  defp uid_start_conflict?(changeset) do
    Enum.any?(changeset.errors, fn
      {:uid_start, {_message, metadata}} ->
        metadata[:constraint] == :unique and
          to_string(metadata[:constraint_name]) == "allocation_uid_start"

      _error ->
        false
    end)
  end

  defp allocation_records_remain?(biot_id) do
    Repo.exists?(from(row in InstallationRow, where: row.biot_id == ^biot_id)) or
      Repo.exists?(from(row in ResolutionRow, where: row.biot_id == ^biot_id))
  end

  defp initialized?(:uninitialized), do: false
  defp initialized?(:complete), do: true
  defp initialization(false), do: :uninitialized
  defp initialization(true), do: :complete

  defp transaction_value({:ok, value}), do: value
  defp transaction_value({:error, reason}), do: {:error, reason}
end
