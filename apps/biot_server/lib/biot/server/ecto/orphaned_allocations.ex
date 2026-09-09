defmodule Biot.Server.Ecto.OrphanedAllocations do
  @moduledoc "Stores node orphan reports as JSON and loads protocol Biot IDs."

  use Ecto.Type

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.ParsedList
  alias Biot.Server.Ecto.Json

  @type allocation :: {biot_id :: BiotId.t(), uid_range :: {non_neg_integer(), pos_integer()}}

  @impl true
  def type, do: :map

  @impl true
  def cast(values) when is_list(values), do: validate(values)
  def cast(_value), do: :error

  @impl true
  def load(value) do
    with {:ok, values} <- Json.fetch(value, "allocations"),
         {:ok, allocations} <- ParsedList.parse(values, &parse_allocation/1) do
      {:ok, allocations}
    else
      _error -> Json.corrupt!(__MODULE__, value)
    end
  end

  @impl true
  def dump(values) do
    {:ok,
     %{
       "allocations" =>
         Enum.map(values, fn {biot_id, {start, count}} ->
           %{"biot_id" => BiotId.to_string(biot_id), "start" => start, "count" => count}
         end)
     }}
  end

  defp parse_allocation(value) do
    with {:ok, biot_id} <- Json.fetch(value, "biot_id"),
         {:ok, biot_id} <- Json.parse(BiotId, biot_id),
         {:ok, start} when is_integer(start) and start >= 0 <- Json.fetch(value, "start"),
         {:ok, count} when is_integer(count) and count > 0 <- Json.fetch(value, "count") do
      {:ok, {biot_id, {start, count}}}
    else
      _error -> {:error, :invalid_format}
    end
  end

  defp validate(values) do
    if Enum.all?(values, &valid?/1), do: {:ok, values}, else: :error
  end

  defp valid?({%BiotId{}, {start, count}})
       when is_integer(start) and start >= 0 and is_integer(count) and count > 0,
       do: true

  defp valid?(_value), do: false
end
