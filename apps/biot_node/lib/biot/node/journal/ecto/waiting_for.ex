defmodule Biot.Node.Journal.Ecto.WaitingFor do
  @moduledoc "Stores what a biot is waiting for as one JSON value, through the protocol's codec."

  use Ecto.Type

  alias Biot.Protocol.ExecutionReport

  @impl true
  def type, do: :map

  @impl true
  def cast(nil), do: {:ok, nil}
  def cast({:fetch_credential, _source} = waiting_for), do: {:ok, waiting_for}
  def cast(_value), do: :error

  @impl true
  def load(value) do
    case ExecutionReport.parse_waiting_for(value) do
      {:ok, waiting_for} ->
        {:ok, waiting_for}

      {:error, _reason} ->
        raise ArgumentError, "stored waiting_for is corrupt: #{inspect(value)}"
    end
  end

  @impl true
  def dump(nil), do: {:ok, nil}

  def dump({:fetch_credential, _source} = waiting_for) do
    {:ok, ExecutionReport.encode_waiting_for(waiting_for)}
  end

  def dump(_value), do: :error
end
