defmodule Biot.Protocol.AgentReply do
  @moduledoc """
  The one line the agent replies with after it accepts a connection and reads a target.

  A rejection carries only a closed cause. The node maps it to a stream failure and never
  forwards the agent's own text.
  """

  alias Biot.Protocol.Choice
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
         {:ok, rejection} <- Choice.parse(error, @rejections) do
      {:ok, {:error, rejection}}
    end
  end

  def parse(_value), do: {:error, :invalid_format}
end
