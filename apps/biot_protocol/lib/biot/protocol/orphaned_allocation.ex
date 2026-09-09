defmodule Biot.Protocol.OrphanedAllocation do
  @moduledoc "An allocation found on a node without matching server intent."

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.StrictMap

  @fields ["biot_id", "uid_range"]
  @uid_range_fields ["start", "count"]

  @enforce_keys [:biot_id, :uid_range]
  defstruct [:biot_id, :uid_range]

  @type uid_range :: %{start: non_neg_integer(), count: pos_integer()}
  @type t :: %__MODULE__{biot_id: BiotId.t(), uid_range: uid_range()}

  @spec encode(t()) :: map()
  def encode(%__MODULE__{biot_id: biot_id, uid_range: %{start: start, count: count}}) do
    %{
      "biot_id" => BiotId.to_string(biot_id),
      "uid_range" => %{"start" => start, "count" => count}
    }
  end

  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_format}
  def parse(value) do
    with {:ok, %{"biot_id" => biot_id_value, "uid_range" => uid_range}} <-
           StrictMap.fetch_exact(value, @fields),
         {:ok, biot_id} <- BiotId.parse(biot_id_value),
         {:ok, %{"start" => start, "count" => count}} <-
           StrictMap.fetch_exact(uid_range, @uid_range_fields),
         true <- is_integer(start) and start >= 0,
         true <- is_integer(count) and count > 0 do
      {:ok, %__MODULE__{biot_id: biot_id, uid_range: %{start: start, count: count}}}
    else
      _error -> {:error, :invalid_format}
    end
  end
end
