defmodule Biot.Protocol.AgentReply do
  @moduledoc """
  The one line the agent replies with after it accepts a connection and reads a target.

  A rejection carries only a closed cause. The node maps it to a stream failure and never
  forwards the agent's own text.
  """

  alias Biot.Protocol.StrictMap

  @rejections ~w(invalid_request connection_refused)a

  @type rejection :: :invalid_request | :connection_refused
  @type t :: :ok | {:error, rejection()}

  @spec rejections() :: [rejection()]
  def rejections, do: @rejections

  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_format}
  def parse(%{"ok" => true} = value) do
    with {:ok, _value} <- StrictMap.fetch_exact(value, ["ok"]), do: {:ok, :ok}
  end

  def parse(%{"ok" => false, "error" => error} = value) do
    with {:ok, _value} <- StrictMap.fetch_exact(value, ["ok", "error"]),
         {:ok, rejection} <- parse_rejection(error) do
      {:ok, {:error, rejection}}
    end
  end

  def parse(_value), do: {:error, :invalid_format}

  defp parse_rejection(value) when is_binary(value) do
    case Enum.find(@rejections, &(Atom.to_string(&1) == value)) do
      nil -> {:error, :invalid_format}
      rejection -> {:ok, rejection}
    end
  end

  defp parse_rejection(_value), do: {:error, :invalid_format}
end
