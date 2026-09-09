defmodule Biot.Node.Control.Staging do
  @moduledoc "Stages one bounded synchronization snapshot before it replaces local intent."

  alias Biot.Protocol.BiotSpec
  alias Biot.Protocol.ConnectionId

  @enforce_keys [:connection_id, :expected_count, :specs]
  defstruct [:connection_id, :expected_count, :specs]

  @type t :: %__MODULE__{
          connection_id: ConnectionId.t(),
          expected_count: non_neg_integer(),
          specs: %{Biot.Protocol.BiotId.t() => BiotSpec.t()}
        }

  @type reason ::
          :snapshot_count_over_capacity
          | :staged_count_exceeded
          | :duplicate_biot_id
          | :synchronize_connection_mismatch
          | :synchronize_count_mismatch

  @spec begin(ConnectionId.t(), non_neg_integer(), pos_integer()) ::
          {:ok, t()} | {:error, reason()}
  def begin(%ConnectionId{} = connection_id, count, max_staged_specs) do
    # The count limit and the wire's per-spec limit bound staged bytes by count times spec size.
    if count <= max_staged_specs do
      {:ok,
       %__MODULE__{
         connection_id: connection_id,
         expected_count: count,
         specs: %{}
       }}
    else
      {:error, :snapshot_count_over_capacity}
    end
  end

  @spec add(t(), BiotSpec.t()) :: {:ok, t()} | {:error, reason()}
  def add(%__MODULE__{} = staging, %BiotSpec{} = spec) do
    biot_id = spec.execution.biot_id

    with :ok <- unique_biot(staging, biot_id),
         :ok <- room_for_item(staging) do
      {:ok, %{staging | specs: Map.put(staging.specs, biot_id, spec)}}
    end
  end

  defp unique_biot(staging, biot_id) do
    if Map.has_key?(staging.specs, biot_id), do: {:error, :duplicate_biot_id}, else: :ok
  end

  defp room_for_item(staging) when map_size(staging.specs) < staging.expected_count, do: :ok
  defp room_for_item(_staging), do: {:error, :staged_count_exceeded}

  @spec complete(t(), ConnectionId.t()) :: {:ok, [BiotSpec.t()]} | {:error, reason()}
  def complete(%__MODULE__{connection_id: connection_id} = staging, connection_id) do
    if map_size(staging.specs) == staging.expected_count do
      {:ok, Map.values(staging.specs)}
    else
      {:error, :synchronize_count_mismatch}
    end
  end

  def complete(%__MODULE__{}, %ConnectionId{}), do: {:error, :synchronize_connection_mismatch}
end
