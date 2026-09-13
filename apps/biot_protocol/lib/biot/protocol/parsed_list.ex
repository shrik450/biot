defmodule Biot.Protocol.ParsedList do
  @moduledoc "Parses every value in a list while preserving its order."

  @spec parse(term(), (term() -> {:ok, term()} | {:error, term()})) ::
          {:ok, [term()]} | {:error, term()}
  def parse(values, parser) do
    case parse_indexed(values, parser) do
      {:error, {_index, reason}} -> {:error, reason}
      result -> result
    end
  end

  @spec parse_indexed(term(), (term() -> {:ok, term()} | {:error, term()})) ::
          {:ok, [term()]} | {:error, {non_neg_integer(), term()}} | {:error, :invalid_format}
  def parse_indexed(values, parser) when is_list(values) and is_function(parser, 1) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, &parse_indexed_value(&1, &2, parser))
    |> finish()
  end

  def parse_indexed(_values, _parser), do: {:error, :invalid_format}

  defp parse_indexed_value({value, index}, {:ok, parsed}, parser) do
    case parser.(value) do
      {:ok, value} -> {:cont, {:ok, [value | parsed]}}
      {:error, reason} -> {:halt, {:error, {index, reason}}}
    end
  end

  defp finish({:ok, parsed}), do: {:ok, Enum.reverse(parsed)}
  defp finish({:error, reason}), do: {:error, reason}
end
