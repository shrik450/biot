defmodule Biot.Server.Ecto.Failure do
  @moduledoc "Stores a lifecycle failure as JSON and loads it as a protocol Failure."

  use Ecto.Type

  alias Biot.Protocol.Failure
  alias Biot.Server.Ecto.Json

  @impl true
  def type, do: :map

  @impl true
  def cast(%Failure{} = failure), do: {:ok, failure}
  def cast(_value), do: :error

  @impl true
  def load(value) do
    case Failure.parse(value) do
      {:ok, failure} -> {:ok, failure}
      {:error, _reason} -> Json.corrupt!(__MODULE__, value)
    end
  end

  @impl true
  def dump(%Failure{} = failure), do: {:ok, Failure.encode(failure)}

  def dump(_value), do: :error
end
