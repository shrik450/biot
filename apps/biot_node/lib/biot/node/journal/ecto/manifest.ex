defmodule Biot.Node.Journal.Ecto.Manifest do
  @moduledoc "Stores a resolved manifest as one JSON value."

  use Ecto.Type

  alias Biot.Protocol.Manifest

  @impl true
  def type, do: :map

  @impl true
  def cast(%Manifest{} = manifest), do: {:ok, manifest}
  def cast(_value), do: :error

  @impl true
  def load(value) do
    case Manifest.parse(value) do
      {:ok, manifest} -> {:ok, manifest}
      {:error, _reason} -> raise ArgumentError, "stored manifest is corrupt: #{inspect(value)}"
    end
  end

  @impl true
  def dump(%Manifest{} = manifest), do: {:ok, Manifest.encode(manifest)}
  def dump(_value), do: :error
end
