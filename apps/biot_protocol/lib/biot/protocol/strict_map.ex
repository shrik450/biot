defmodule Biot.Protocol.StrictMap do
  @moduledoc "Checks that a parsed map contains exactly the expected keys."

  @spec fetch_exact(term(), [term()]) :: {:ok, map()} | {:error, :invalid_format}
  def fetch_exact(value, keys) when is_map(value) and is_list(keys) do
    if map_size(value) == length(keys) and Enum.all?(keys, &Map.has_key?(value, &1)) do
      {:ok, value}
    else
      {:error, :invalid_format}
    end
  end

  def fetch_exact(_value, _keys), do: {:error, :invalid_format}
end
