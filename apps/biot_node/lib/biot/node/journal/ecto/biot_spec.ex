defmodule Biot.Node.Journal.Ecto.BiotSpec do
  @moduledoc "Stores the last accepted BiotSpec as one JSON value."

  use Ecto.Type

  alias Biot.Protocol.BiotSpec

  @impl true
  def type, do: :map

  @impl true
  def cast(%BiotSpec{} = spec), do: {:ok, spec}
  def cast(_value), do: :error

  @impl true
  def load(value) do
    case BiotSpec.parse(value) do
      {:ok, spec} -> {:ok, spec}
      {:error, _reason} -> raise ArgumentError, "stored BiotSpec is corrupt: #{inspect(value)}"
    end
  end

  @impl true
  def dump(%BiotSpec{} = spec), do: {:ok, BiotSpec.encode(spec)}
  def dump(_value), do: :error
end
