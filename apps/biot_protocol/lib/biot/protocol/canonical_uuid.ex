defmodule Biot.Protocol.CanonicalUuid do
  @moduledoc false

  @uuid_pattern ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  @spec parse(term()) :: {:ok, String.t()} | {:error, :invalid_format}
  def parse(value) when is_binary(value) do
    if Regex.match?(@uuid_pattern, value) do
      {:ok, value}
    else
      {:error, :invalid_format}
    end
  end

  def parse(_value), do: {:error, :invalid_format}
end
