defmodule Biot.Server.Ecto.ObservationContainer do
  @moduledoc "Stores the observed container sum type as tagged JSON."

  use Ecto.Type

  alias Biot.Protocol.ExecutionReport
  alias Biot.Protocol.IncarnationId
  alias Biot.Server.Ecto.Json

  @type container :: ExecutionReport.container()

  @impl true
  def type, do: :map

  @impl true
  def cast(:unknown), do: {:ok, :unknown}
  def cast(:absent), do: {:ok, :absent}

  def cast({:present, %IncarnationId{}, :running} = value),
    do: {:ok, value}

  def cast({:present, %IncarnationId{}, {:exited, status}} = value)
      when is_integer(status) and status >= 0,
      do: {:ok, value}

  def cast(_value), do: :error

  @impl true
  def load(value) do
    case ExecutionReport.parse_container(value) do
      {:ok, container} -> {:ok, container}
      {:error, _reason} -> Json.corrupt!(__MODULE__, value)
    end
  end

  @impl true
  def dump(:unknown), do: {:ok, ExecutionReport.encode_container(:unknown)}
  def dump(:absent), do: {:ok, ExecutionReport.encode_container(:absent)}

  def dump({:present, %IncarnationId{}, _container_state} = container),
    do: {:ok, ExecutionReport.encode_container(container)}

  def dump(_value), do: :error
end
