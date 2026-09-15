defmodule Biot.Server.OperatorFile do
  @moduledoc """
  Reads one operator-owned JSON file that holds a list, and parses each entry.

  Node enrollment and disabled principals are both kept this way. An unset path is an empty list,
  because the operator has configured nothing.
  """

  alias Biot.Protocol.ParsedList

  @type error(entry_error) ::
          :not_a_list
          | {:file, Path.t(), File.posix()}
          | {:invalid_json, String.t()}
          | {:entry, non_neg_integer(), entry_error}

  @spec load(Path.t() | nil, (term() -> {:ok, value} | {:error, reason})) ::
          {:ok, [value]} | {:error, error(reason)}
        when value: term(), reason: term()
  def load(nil, _parse), do: {:ok, []}

  def load(path, parse) when is_binary(path) do
    case read(path) do
      {:ok, entries} when is_list(entries) -> parse_entries(entries, parse)
      {:ok, _value} -> {:error, :not_a_list}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "A readable message about the file `label` names, such as `\"node registrations\"`."
  @spec message(String.t(), error(term())) :: String.t()
  def message(label, :not_a_list), do: "#{label} must be a list"

  def message(label, {:file, path, reason}),
    do: "could not read #{label} from #{path}: #{:file.format_error(reason)}"

  def message(label, {:invalid_json, message}), do: "#{label} contain invalid JSON: #{message}"

  def message(label, {:entry, index, {field, reason}}),
    do: "entry #{index} of #{label} has invalid #{field}: #{reason}"

  def message(label, {:entry, index, reason}),
    do: "entry #{index} of #{label} is invalid: #{inspect(reason)}"

  defp read(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, value} -> {:ok, value}
          {:error, error} -> {:error, {:invalid_json, Exception.message(error)}}
        end

      {:error, reason} ->
        {:error, {:file, path, reason}}
    end
  end

  defp parse_entries(entries, parse) do
    case ParsedList.parse_indexed(entries, parse) do
      {:ok, values} -> {:ok, values}
      {:error, {index, reason}} -> {:error, {:entry, index, reason}}
    end
  end
end
