defmodule Biot.Protocol.Port do
  @moduledoc "A TCP port in the valid user-facing range."

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: 1..65_535}

  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_format | :out_of_range}
  def parse(value) when is_integer(value) do
    if value in 1..65_535 do
      {:ok, %__MODULE__{value: value}}
    else
      {:error, :out_of_range}
    end
  end

  def parse(value) when is_binary(value) do
    if Regex.match?(~r/\A(?:0|[1-9][0-9]*)\z/, value) do
      value |> String.to_integer() |> parse()
    else
      {:error, :invalid_format}
    end
  end

  def parse(_value), do: {:error, :invalid_format}

  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{value: value}), do: Integer.to_string(value)
end

defimpl String.Chars, for: Biot.Protocol.Port do
  def to_string(value), do: Biot.Protocol.Port.to_string(value)
end
