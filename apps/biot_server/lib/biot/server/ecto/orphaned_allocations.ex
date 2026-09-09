defmodule Biot.Server.Ecto.OrphanedAllocations do
  @moduledoc "Stores node orphan reports as JSON and loads protocol allocations."

  use Ecto.Type

  alias Biot.Protocol.OrphanedAllocation
  alias Biot.Protocol.ParsedList
  alias Biot.Server.Ecto.Json

  @impl true
  def type, do: :map

  @impl true
  def cast(values) when is_list(values) do
    if Enum.all?(values, &match?(%OrphanedAllocation{}, &1)), do: {:ok, values}, else: :error
  end

  def cast(_value), do: :error

  @impl true
  def load(value) do
    with {:ok, values} <- Json.fetch(value, "allocations"),
         {:ok, allocations} <- ParsedList.parse(values, &OrphanedAllocation.parse/1) do
      {:ok, allocations}
    else
      _error -> Json.corrupt!(__MODULE__, value)
    end
  end

  @impl true
  def dump(values) when is_list(values) do
    if Enum.all?(values, &match?(%OrphanedAllocation{}, &1)) do
      {:ok, %{"allocations" => Enum.map(values, &OrphanedAllocation.encode/1)}}
    else
      :error
    end
  end

  def dump(_value), do: :error
end
