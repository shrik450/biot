defmodule Biot.Server.Ecto.EnvironmentSelection do
  @moduledoc "Stores an environment selection as one JSON value because no query selects its individual parts."

  use Ecto.Type

  alias Biot.Protocol.EnvironmentSelection
  alias Biot.Server.Ecto.Json

  @impl true
  def type, do: :map

  @impl true
  def cast(%EnvironmentSelection{} = selection), do: {:ok, selection}
  def cast(_value), do: :error

  @impl true
  def load(value) do
    case EnvironmentSelection.parse(value) do
      {:ok, selection} -> {:ok, selection}
      {:error, _reason} -> Json.corrupt!(__MODULE__, value)
    end
  end

  @impl true
  def dump(%EnvironmentSelection{} = selection),
    do: {:ok, EnvironmentSelection.encode(selection)}

  def dump(_value), do: :error
end
