defmodule Biot.Protocol.IncarnationId do
  @moduledoc """
  Podman's full native ID for one container incarnation, kept as an opaque value.

  The node never mints one. Podman assigns it when it creates the container, and inspection of the
  Biot's stable container name is how the node learns it.
  """

  @enforce_keys [:value]
  defstruct [:value]

  @opaque t :: %__MODULE__{value: String.t()}

  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_format}
  def parse(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, value),
      do: {:ok, %__MODULE__{value: value}},
      else: {:error, :invalid_format}
  end

  def parse(_value), do: {:error, :invalid_format}

  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{value: value}), do: value
end

defimpl String.Chars, for: Biot.Protocol.IncarnationId do
  def to_string(value), do: Biot.Protocol.IncarnationId.to_string(value)
end
