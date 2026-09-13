defmodule Biot.Protocol.CredentialId do
  @moduledoc "An opaque identity for one bearer credential."

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

defimpl String.Chars, for: Biot.Protocol.CredentialId do
  def to_string(value), do: Biot.Protocol.CredentialId.to_string(value)
end
