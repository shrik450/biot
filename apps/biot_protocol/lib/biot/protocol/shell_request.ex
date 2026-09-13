defmodule Biot.Protocol.ShellRequest do
  @moduledoc """
  The parameters of one shell stream: its terminal, initial size, and optional command.

  A `nil` command runs the bundle's shell entry as a login shell. A list runs through that same
  entry instead. The fields mirror the agent's own strict request line, including its refusal of a
  NUL byte. Text that is not valid UTF-8 is refused too, because the target's agent line is encoded
  as JSON and a value this module accepts must always encode.
  """

  alias Biot.Protocol.StrictMap

  @fields ["term", "cols", "rows", "command"]

  @enforce_keys [:term, :cols, :rows, :command]
  defstruct [:term, :cols, :rows, :command]

  @type t :: %__MODULE__{
          term: String.t(),
          cols: 1..65_535,
          rows: 1..65_535,
          command: nil | [String.t()]
        }

  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = request) do
    %{
      "term" => request.term,
      "cols" => request.cols,
      "rows" => request.rows,
      "command" => request.command
    }
  end

  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_format}
  def parse(value) do
    with {:ok, value} <- StrictMap.fetch_exact(value, @fields),
         {:ok, term} <- parse_term(value["term"]),
         {:ok, cols} <- parse_size(value["cols"]),
         {:ok, rows} <- parse_size(value["rows"]),
         {:ok, command} <- parse_command(value["command"]) do
      {:ok, %__MODULE__{term: term, cols: cols, rows: rows, command: command}}
    else
      _error -> {:error, :invalid_format}
    end
  end

  defp parse_term(value) when is_binary(value) and value != "" do
    if valid_text?(value), do: {:ok, value}, else: {:error, :invalid_format}
  end

  defp parse_term(_value), do: {:error, :invalid_format}

  defp parse_size(value) when is_integer(value) and value in 1..65_535, do: {:ok, value}
  defp parse_size(_value), do: {:error, :invalid_format}

  defp parse_command(nil), do: {:ok, nil}

  defp parse_command([]), do: {:error, :invalid_format}

  defp parse_command(value) when is_list(value) do
    if Enum.all?(value, &valid_text?/1),
      do: {:ok, value},
      else: {:error, :invalid_format}
  end

  defp parse_command(_value), do: {:error, :invalid_format}

  defp valid_text?(value) when is_binary(value) do
    String.valid?(value) and :binary.match(value, <<0>>) == :nomatch
  end

  defp valid_text?(_value), do: false
end
