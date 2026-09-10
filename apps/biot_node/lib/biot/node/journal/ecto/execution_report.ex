defmodule Biot.Node.Journal.Ecto.ExecutionReport do
  @moduledoc "Stores a final execution report as one JSON value."

  use Ecto.Type

  alias Biot.Protocol.ExecutionReport

  @impl true
  def type, do: :map

  @impl true
  def cast(%ExecutionReport{} = report), do: {:ok, report}
  def cast(_value), do: :error

  @impl true
  def load(value) do
    case ExecutionReport.parse(value) do
      {:ok, report} ->
        {:ok, report}

      {:error, _reason} ->
        raise ArgumentError, "stored execution report is corrupt: #{inspect(value)}"
    end
  end

  @impl true
  def dump(%ExecutionReport{} = report), do: {:ok, ExecutionReport.encode(report)}
  def dump(_value), do: :error
end
