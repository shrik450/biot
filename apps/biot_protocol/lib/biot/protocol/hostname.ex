defmodule Biot.Protocol.Hostname do
  @moduledoc "A lowercase DNS label suitable for a biot subdomain."

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: String.t()}

  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_format}
  def parse(value) when is_binary(value) do
    if Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/, value) do
      {:ok, %__MODULE__{value: value}}
    else
      {:error, :invalid_format}
    end
  end

  def parse(_value), do: {:error, :invalid_format}

  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{value: value}), do: value
end

defimpl String.Chars, for: Biot.Protocol.Hostname do
  def to_string(value), do: Biot.Protocol.Hostname.to_string(value)
end
