defmodule Biot.Node.NetworkId do
  @moduledoc "The identity of the private network derived from its owning Biot."

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.CanonicalUuid

  @enforce_keys [:value]
  defstruct [:value]

  @opaque t :: %__MODULE__{value: String.t()}

  @spec from_biot_id(BiotId.t()) :: t()
  def from_biot_id(%BiotId{} = biot_id), do: %__MODULE__{value: BiotId.to_string(biot_id)}

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
