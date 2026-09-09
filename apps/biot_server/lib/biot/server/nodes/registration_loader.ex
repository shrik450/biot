defmodule Biot.Server.Nodes.RegistrationLoader do
  @moduledoc "Loads and parses node registrations without changing database state."

  alias Biot.Server.Nodes.Registration

  @spec load() :: {:ok, [Registration.t()]} | {:error, term()}
  def load do
    case Application.fetch_env(:biot_server, :node_registrations) do
      {:ok, registrations} -> parse(registrations)
      :error -> load_file(Application.get_env(:biot_server, :node_registrations_file))
    end
  end

  @spec message(term()) :: String.t()
  def message(:registrations_must_be_a_list), do: "node registrations must be a list"
  def message({:invalid_path, path}), do: "node registration path is invalid: #{inspect(path)}"

  def message({:file, path, reason}) do
    "could not read node registrations from #{path}: #{:file.format_error(reason)}"
  end

  def message({:invalid_json, message}), do: "node registrations contain invalid JSON: #{message}"

  def message({:registration, index, {field, reason}}) do
    "node registration #{index} has invalid #{field}: #{reason}"
  end

  def message({:registration, index, reason}) do
    "node registration #{index} is invalid: #{inspect(reason)}"
  end

  defp load_file(nil), do: {:ok, []}

  defp load_file(path) when is_binary(path) and path != "" do
    with {:ok, contents} <- File.read(path),
         {:ok, registrations} <- Jason.decode(contents) do
      parse(registrations)
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:invalid_json, Exception.message(error)}}

      {:error, reason} ->
        {:error, {:file, path, reason}}
    end
  end

  defp load_file(path), do: {:error, {:invalid_path, path}}

  defp parse(registrations) when is_list(registrations) do
    registrations
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, parsed} ->
      case parse_registration(value) do
        {:ok, registration} -> {:cont, {:ok, [registration | parsed]}}
        {:error, reason} -> {:halt, {:error, {:registration, index, reason}}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse(_registrations), do: {:error, :registrations_must_be_a_list}

  defp parse_registration(%Registration{} = registration), do: {:ok, registration}
  defp parse_registration(value), do: Registration.parse(value)
end
