defmodule Biot.Node.ArtifactId do
  @moduledoc """
  The identity of one prepared environment artifact on this node. The environment implementation
  mints it and decides what it says; reconciliation only compares it and passes it to an install.
  """

  @enforce_keys [:value]
  defstruct [:value]

  @opaque t :: %__MODULE__{value: String.t()}

  # The environment implementation owns what this token says, and the host layer owns passing it
  # safely, so a non-empty printable string is the whole rule.
  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_format}
  def parse(value) when is_binary(value) and byte_size(value) > 0 do
    if String.printable?(value),
      do: {:ok, %__MODULE__{value: value}},
      else: {:error, :invalid_format}
  end

  def parse(_value), do: {:error, :invalid_format}

  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{value: value}), do: value
end

defimpl String.Chars, for: Biot.Node.ArtifactId do
  def to_string(value), do: Biot.Node.ArtifactId.to_string(value)
end
