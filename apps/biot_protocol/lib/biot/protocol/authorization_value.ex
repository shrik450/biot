defmodule Biot.Protocol.AuthorizationValue do
  @moduledoc """
  One HTTP authorization value, scoped by its caller to a single parsed HTTPS source.

  It is an HTTP field value and nothing more: visible ASCII with spaces and tabs, no control
  characters, so a delivered value cannot inject a second header line into the request that
  carries it. It redacts itself the same way `Biot.Protocol.SecretValue` does.
  """

  alias Biot.Protocol.Limits

  @derive {Inspect, only: []}
  @enforce_keys [:value]
  defstruct [:value]

  @opaque t :: %__MODULE__{value: String.t()}

  @spec parse(term(), pos_integer()) ::
          {:ok, t()} | {:error, :invalid_format | :secret_value_too_large}
  def parse(value, version) when is_binary(value) do
    cond do
      byte_size(value) > Limits.max_secret_value_bytes(version) ->
        {:error, :secret_value_too_large}

      field_value?(value) ->
        {:ok, %__MODULE__{value: value}}

      true ->
        {:error, :invalid_format}
    end
  end

  def parse(_value, _version), do: {:error, :invalid_format}

  @doc "The field value to send. Every caller of this is a boundary that has to hold the value."
  @spec reveal(t()) :: String.t()
  def reveal(%__MODULE__{value: value}), do: value

  # RFC 9110 field-content: one or more visible characters, with space and tab allowed between
  # them. A leading or trailing space is stripped by every parser that reads the field back, so a
  # value that depends on one is not the value that would arrive.
  defp field_value?(value) do
    Regex.match?(~r/\A[\x21-\x7e](?:[\x20-\x7e\t]*[\x21-\x7e])?\z/, value)
  end
end
