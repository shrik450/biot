defmodule Biot.Protocol.ContainerState do
  @moduledoc "The observed execution state of a container."

  @type t :: :running | {:exited, non_neg_integer()}

  @spec encode(t()) :: map()
  def encode(:running), do: %{"state" => "running"}
  def encode({:exited, status}), do: %{"state" => "exited", "status" => status}

  @spec parse(term()) :: {:ok, t()} | {:error, atom()}
  def parse(%{"state" => "running"}), do: {:ok, :running}

  def parse(%{"state" => "exited", "status" => status})
      when is_integer(status) and status >= 0,
      do: {:ok, {:exited, status}}

  def parse(_value), do: {:error, :invalid_format}
end
