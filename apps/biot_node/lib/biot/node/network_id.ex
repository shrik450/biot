defmodule Biot.Node.NetworkId do
  @moduledoc "The node-minted identity of the private network one allocation owns."

  alias Biot.Protocol.CanonicalUuid

  @enforce_keys [:value]
  defstruct [:value]

  @opaque t :: %__MODULE__{value: String.t()}

  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_format}
  def parse(value) do
    with {:ok, value} <- CanonicalUuid.parse(value) do
      {:ok, %__MODULE__{value: value}}
    end
  end

  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{value: value}), do: value
end

defimpl String.Chars, for: Biot.Node.NetworkId do
  def to_string(value), do: Biot.Node.NetworkId.to_string(value)
end
