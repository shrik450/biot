defmodule Biot.Protocol.BiotName do
  @moduledoc """
  An owner's name for a Biot: a lowercase DNS label.

  Names appear in URLs, command lines, and logs, so they carry no spaces, slashes, or case to
  normalize. A name that is a canonical UUID is rejected, so a client can tell a name from a
  `BiotId` without asking the server.
  """

  alias Biot.Protocol.CanonicalUuid

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: String.t()}

  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_format}
  def parse(value) when is_binary(value) do
    if Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/, value) and
         not match?({:ok, _uuid}, CanonicalUuid.parse(value)) do
      {:ok, %__MODULE__{value: value}}
    else
      {:error, :invalid_format}
    end
  end

  def parse(_value), do: {:error, :invalid_format}

  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{value: value}), do: value
end

defimpl String.Chars, for: Biot.Protocol.BiotName do
  def to_string(value), do: Biot.Protocol.BiotName.to_string(value)
end
