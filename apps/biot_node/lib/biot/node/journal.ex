defmodule Biot.Node.Journal do
  @moduledoc "Owns node-local SQLite records and their domain values."

  import Ecto.Query

  alias Biot.Node.Allocation
  alias Biot.Node.ArtifactId
  alias Biot.Node.Installation
  alias Biot.Node.Journal.Schema.Allocation, as: AllocationRow
  alias Biot.Node.Journal.Schema.Installation, as: InstallationRow
  alias Biot.Node.Journal.Schema.LocalIntent, as: LocalIntentRow
  alias Biot.Node.Journal.Schema.Resolution, as: ResolutionRow
  alias Biot.Node.LocalIntent
  alias Biot.Node.MarkerId
  alias Biot.Node.Repo
  alias Biot.Node.Resolution
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.BiotSpec
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.Manifest

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

  @spec complete_initialization(Allocation.t(), MarkerId.t()) ::
          {:ok, Allocation.t()} | {:error, term()}
  def complete_initialization(%Allocation{} = allocation, %MarkerId{} = marker_id) do
    Repo.transaction(
      fn ->
        row = current_allocation!(allocation)

        case row.initialization_marker do
          nil ->
            row
            |> Ecto.Changeset.change(initialization_marker: marker_id)
            |> Repo.update!()
            |> allocation_value()

          ^marker_id ->
            allocation_value(row)

          _other ->
            Repo.rollback(:stale)
        end
      end,
      mode: :immediate
    )
  end

  @spec reset_initialization(Allocation.t()) :: :ok | {:error, term()}
  def reset_initialization(%Allocation{} = allocation) do
    Repo.transaction(
      fn ->
        allocation
        |> current_allocation!()
        |> Ecto.Changeset.change(initialization_marker: nil)
        |> Repo.update!()

        :ok
      end,
      mode: :immediate
    )
    |> transaction_value()
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

  @spec put_intent(BiotSpec.t()) :: {:ok, LocalIntent.t()} | {:error, :invalid_intent}
  def put_intent(%BiotSpec{} = spec) do
    case upsert_intent(spec) do
      {:ok, row} -> {:ok, intent_value(row)}
      {:error, _changeset} -> {:error, :invalid_intent}
    end
  end

  @doc """
  Replaces every local intent with the synchronized set. A biot the server no longer sends intent
  for loses its row, which stops its controller and leaves its allocation to be reported as an
  orphan.
  """
  @spec replace_intents([BiotSpec.t()]) :: :ok | {:error, term()}
  def replace_intents(specs) when is_list(specs) do
    Repo.transaction(
      fn ->
        Enum.each(specs, fn spec -> {:ok, _row} = upsert_intent(spec) end)
        synchronized = Enum.map(specs, & &1.execution.biot_id)

        LocalIntentRow
        |> where([row], row.biot_id not in ^synchronized)
        |> Repo.delete_all()

        :ok
      end,
      mode: :immediate
    )
    |> transaction_value()
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

  defp intent_value(row), do: %LocalIntent{biot_id: row.biot_id, biot_spec: row.biot_spec}

  defp allocation_row(allocation) do
    %AllocationRow{
      biot_id: allocation.biot_id,
      uid_start: allocation.uid_range.start,
      uid_count: allocation.uid_range.count,
      data_root: allocation.data_root,
      network_id: allocation.network_id,
      initialization_marker: initialization_marker(allocation.initialization)
    }
  end

  defp allocation_value(row) do
    %Allocation{
      biot_id: row.biot_id,
      uid_range: %{start: row.uid_start, count: row.uid_count},
      data_root: row.data_root,
      network_id: row.network_id,
      initialization: initialization(row.initialization_marker)
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

  defp initialization_marker(:uninitialized), do: nil
  defp initialization_marker({:complete, marker_id}), do: marker_id
  defp initialization(nil), do: :uninitialized
  defp initialization(marker_id), do: {:complete, marker_id}

  defp transaction_value({:ok, value}), do: value
  defp transaction_value({:error, reason}), do: {:error, reason}
end
