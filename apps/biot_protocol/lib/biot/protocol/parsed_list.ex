defmodule Biot.Protocol.ParsedList do
  @moduledoc "Parses every value in a list while preserving its order."

  @spec parse(term(), (term() -> {:ok, term()} | {:error, term()})) ::
          {:ok, [term()]} | {:error, term()}
  def parse(values, parser) when is_list(values) and is_function(parser, 1) do
    values
    |> Enum.reduce_while({:ok, []}, &parse_value(&1, &2, parser))
    |> finish()
  end

  def parse(_values, _parser), do: {:error, :invalid_format}

  defp parse_value(value, {:ok, parsed}, parser) do
    case parser.(value) do
      {:ok, value} -> {:cont, {:ok, [value | parsed]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp finish({:ok, parsed}), do: {:ok, Enum.reverse(parsed)}
  defp finish({:error, reason}), do: {:error, reason}
end
