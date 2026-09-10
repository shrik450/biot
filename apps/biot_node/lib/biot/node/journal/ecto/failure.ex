defmodule Biot.Node.Journal.Ecto.Failure do
  @moduledoc "Stores a recorded lifecycle failure as one JSON value."

  use Ecto.Type

  alias Biot.Protocol.Failure

  @impl true
  def type, do: :map

  @impl true
  def cast(%Failure{} = failure), do: {:ok, failure}
  def cast(_value), do: :error

  @impl true
  def load(value) do
    case Failure.parse(value) do
      {:ok, failure} -> {:ok, failure}
      {:error, _reason} -> raise ArgumentError, "stored failure is corrupt: #{inspect(value)}"
    end
  end

  @impl true
  def dump(%Failure{} = failure), do: {:ok, Failure.encode(failure)}
  def dump(_value), do: :error
end
