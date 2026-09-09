defmodule Biot.Protocol.IncarnationId do
  @moduledoc "An opaque identity for one container incarnation."

  alias Biot.Protocol.CanonicalUuid

  @enforce_keys [:value]
  defstruct [:value]

  @opaque t :: %__MODULE__{value: String.t()}

  @spec generate() :: t()
  def generate, do: %__MODULE__{value: CanonicalUuid.generate()}

  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_format}
  def parse(value) do
    with {:ok, value} <- CanonicalUuid.parse(value) do
      {:ok, %__MODULE__{value: value}}
    end
  end

  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{value: value}), do: value
end

defimpl String.Chars, for: Biot.Protocol.IncarnationId do
  def to_string(value), do: Biot.Protocol.IncarnationId.to_string(value)
end
