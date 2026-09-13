defmodule Biot.Protocol.SameOriginPath do
  @moduledoc "An absolute path with an optional query string. Never a full URL."

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: String.t()}

  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_format}
  def parse(value) when is_binary(value) do
    # A leading double slash is a scheme-relative reference, not a path. A
    # backslash is rejected because browsers read it as a slash in special
    # URLs, which can turn a path into an authority-style redirect.
    if Regex.match?(~r{\A/(?!/)[^\s#\\]*\z}, value) do
      {:ok, %__MODULE__{value: value}}
    else
      {:error, :invalid_format}
    end
  end

  def parse(_value), do: {:error, :invalid_format}

  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{value: value}), do: value
end

defimpl String.Chars, for: Biot.Protocol.SameOriginPath do
  def to_string(value), do: Biot.Protocol.SameOriginPath.to_string(value)
end
