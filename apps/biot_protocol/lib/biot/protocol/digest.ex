defmodule Biot.Protocol.Digest do
  @moduledoc "A raw SHA-256 digest with a named canonical encoding."

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: <<_::256>>}

  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_format}
  def parse(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, value) do
      {:ok, %__MODULE__{value: Base.decode16!(value, case: :lower)}}
    else
      {:error, :invalid_format}
    end
  end

  def parse(_value), do: {:error, :invalid_format}

  @spec compute(atom(), iodata()) :: t()
  def compute(name, bytes) when is_atom(name) do
    # The name prefix keeps digests of different encodings from colliding.
    %__MODULE__{value: :crypto.hash(:sha256, [Atom.to_string(name), <<0>>, bytes])}
  end

  @spec sha256(iodata()) :: t()
  def sha256(bytes), do: %__MODULE__{value: :crypto.hash(:sha256, bytes)}

  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{value: value}), do: Base.encode16(value, case: :lower)
end

defimpl String.Chars, for: Biot.Protocol.Digest do
  def to_string(value), do: Biot.Protocol.Digest.to_string(value)
end
