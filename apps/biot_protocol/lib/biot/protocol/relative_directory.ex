defmodule Biot.Protocol.RelativeDirectory do
  @moduledoc "A non-empty relative directory inside a checkout. Its value rejects `.` and `..` segments."

  @enforce_keys [:path]
  defstruct [:path]

  @type t :: %__MODULE__{path: String.t()}

  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_format | :absolute_path | :parent_segment}
  def parse(value) when is_binary(value) do
    segments = String.split(value, "/", trim: false)

    cond do
      invalid_value?(value) ->
        {:error, :invalid_format}

      absolute_path?(value) ->
        {:error, :absolute_path}

      Enum.any?(segments, &(&1 == "")) ->
        {:error, :invalid_format}

      Enum.any?(segments, &(&1 == "..")) ->
        {:error, :parent_segment}

      Enum.any?(segments, &(&1 == ".")) ->
        {:error, :invalid_format}

      true ->
        {:ok, %__MODULE__{path: value}}
    end
  end

  def parse(_value), do: {:error, :invalid_format}

  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{path: path}), do: path

  defp invalid_value?(value) do
    value == "" or not String.valid?(value) or String.contains?(value, <<0>>)
  end

  defp absolute_path?(value), do: String.starts_with?(value, "/")
end

defimpl String.Chars, for: Biot.Protocol.RelativeDirectory do
  def to_string(value), do: Biot.Protocol.RelativeDirectory.to_string(value)
end
