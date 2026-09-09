defmodule Biot.Server.Ecto.ObservationContainer do
  @moduledoc "Stores the observed container sum type as tagged JSON."

  use Ecto.Type

  alias Biot.Protocol.ContainerState
  alias Biot.Server.Ecto.Json

  @type container :: :unknown | :absent | {:present, String.t(), ContainerState.t()}

  @impl true
  def type, do: :map

  @impl true
  def cast(:unknown), do: {:ok, :unknown}
  def cast(:absent), do: {:ok, :absent}

  def cast({:present, incarnation_id, :running} = value)
      when is_binary(incarnation_id) and incarnation_id != "",
      do: {:ok, value}

  def cast({:present, incarnation_id, {:exited, status}} = value)
      when is_binary(incarnation_id) and incarnation_id != "" and is_integer(status) and
             status >= 0,
      do: {:ok, value}

  def cast(_value), do: :error

  @impl true
  def load(value) do
    case Json.fetch(value, "state") do
      {:ok, "unknown"} -> {:ok, :unknown}
      {:ok, "absent"} -> {:ok, :absent}
      {:ok, "present"} -> load_present(value)
      _error -> Json.corrupt!(__MODULE__, value)
    end
  end

  @impl true
  def dump(:unknown), do: {:ok, %{"state" => "unknown"}}
  def dump(:absent), do: {:ok, %{"state" => "absent"}}

  def dump({:present, incarnation_id, :running}) do
    {:ok,
     %{
       "state" => "present",
       "incarnation_id" => incarnation_id,
       "container_state" => ContainerState.encode(:running)
     }}
  end

  def dump({:present, incarnation_id, {:exited, exit_status}}) do
    {:ok,
     %{
       "state" => "present",
       "incarnation_id" => incarnation_id,
       "container_state" => ContainerState.encode({:exited, exit_status})
     }}
  end

  def dump(_value), do: :error

  defp load_present(value) do
    with {:ok, incarnation_id} when is_binary(incarnation_id) and incarnation_id != "" <-
           Json.fetch(value, "incarnation_id"),
         {:ok, container_state} <- Json.fetch(value, "container_state"),
         {:ok, container_state} <- ContainerState.parse(container_state) do
      {:ok, {:present, incarnation_id, container_state}}
    else
      _error -> Json.corrupt!(__MODULE__, value)
    end
  end
end
