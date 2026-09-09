defmodule Biot.Protocol.ContainerState do
  @moduledoc "The observed execution state of a container."

  alias Biot.Protocol.StrictMap

  @type t :: :running | {:exited, non_neg_integer()}

  @spec encode(t()) :: map()
  def encode(:running), do: %{"state" => "running"}
  def encode({:exited, status}), do: %{"state" => "exited", "status" => status}

  @spec parse(term()) :: {:ok, t()} | {:error, atom()}
  def parse(%{"state" => "running"} = value) do
    with {:ok, _value} <- StrictMap.fetch_exact(value, ["state"]), do: {:ok, :running}
  end

  def parse(%{"state" => "exited", "status" => status} = value) do
    with {:ok, _value} <- StrictMap.fetch_exact(value, ["state", "status"]),
         true <- is_integer(status) and status >= 0 do
      {:ok, {:exited, status}}
    else
      _error -> {:error, :invalid_format}
    end
  end

  def parse(_value), do: {:error, :invalid_format}
end
