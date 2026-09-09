defmodule Biot.Server.Ecto.Json do
  @moduledoc false

  @spec fetch(map(), String.t()) :: {:ok, term()} | :error
  def fetch(map, key) when is_map(map), do: Map.fetch(map, key)
  def fetch(_value, _key), do: :error

  @spec parse(module(), term()) :: {:ok, struct()} | :error
  def parse(module, value) do
    case module.parse(value) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _reason} -> :error
    end
  end

  @spec corrupt!(module(), term()) :: no_return()
  def corrupt!(type, value) do
    raise ArgumentError, "stored #{inspect(type)} value is corrupt: #{inspect(value)}"
  end
end
