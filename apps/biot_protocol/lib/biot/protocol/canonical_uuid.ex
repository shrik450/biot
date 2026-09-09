defmodule Biot.Protocol.CanonicalUuid do
  @moduledoc false

  import Bitwise

  @uuid_pattern ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  @spec generate() :: String.t()
  def generate do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    [
      hex(a, 8),
      "-",
      hex(b, 4),
      "-",
      hex((c &&& 0x0FFF) ||| 0x4000, 4),
      "-",
      hex((d &&& 0x3FFF) ||| 0x8000, 4),
      "-",
      hex(e, 12)
    ]
    |> IO.iodata_to_binary()
  end

  @spec parse(term()) :: {:ok, String.t()} | {:error, :invalid_format}
  def parse(value) when is_binary(value) do
    if Regex.match?(@uuid_pattern, value) do
      {:ok, value}
    else
      {:error, :invalid_format}
    end
  end

  def parse(_value), do: {:error, :invalid_format}

  defp hex(value, width) do
    value
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(width, "0")
  end
end
