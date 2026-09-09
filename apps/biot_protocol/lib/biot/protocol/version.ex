defmodule Biot.Protocol.Version do
  @moduledoc "Selects the highest protocol version shared by both peers."

  @supported [1]

  @spec supported() :: [pos_integer()]
  def supported, do: @supported

  @spec select_version([pos_integer()], [pos_integer()]) ::
          {:ok, pos_integer()} | {:error, :unsupported_protocol_version}
  def select_version(offered, supported) do
    case offered
         |> MapSet.new()
         |> MapSet.intersection(MapSet.new(supported))
         |> Enum.max(fn -> nil end) do
      nil -> {:error, :unsupported_protocol_version}
      version -> {:ok, version}
    end
  end
end
