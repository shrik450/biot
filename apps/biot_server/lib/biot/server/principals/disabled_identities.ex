defmodule Biot.Server.Principals.DisabledIdentities do
  @moduledoc "Loads and parses the operator's disabled issuer/subject identities."

  alias Biot.Protocol.ParsedList

  defmodule Identity do
    @moduledoc "One OIDC identity the operator has disabled."

    @enforce_keys [:issuer, :subject]
    defstruct [:issuer, :subject]

    @type t :: %__MODULE__{issuer: String.t(), subject: String.t()}
  end

  @type error ::
          :identities_must_be_a_list
          | {:invalid_path, term()}
          | {:file, String.t(), File.posix()}
          | {:invalid_json, String.t()}
          | {:identity, non_neg_integer(), term()}

  @spec load() :: {:ok, [Identity.t()]} | {:error, error()}
  def load do
    case Application.fetch_env(:biot_server, :disabled_principals) do
      {:ok, identities} -> parse(identities)
      :error -> load_file(Application.get_env(:biot_server, :disabled_principals_file))
    end
  end

  @spec message(error()) :: String.t()
  def message(:identities_must_be_a_list),
    do: "disabled principals must be a list"

  def message({:invalid_path, path}),
    do: "disabled principals path is invalid: #{inspect(path)}"

  def message({:file, path, reason}) do
    "could not read disabled principals from #{path}: #{:file.format_error(reason)}"
  end

  def message({:invalid_json, message}),
    do: "disabled principals contain invalid JSON: #{message}"

  def message({:identity, index, {field, reason}}) do
    "disabled principal #{index} has invalid #{field}: #{reason}"
  end

  def message({:identity, index, reason}) do
    "disabled principal #{index} is invalid: #{inspect(reason)}"
  end

  defp load_file(nil), do: {:ok, []}

  defp load_file(path) when is_binary(path) and path != "" do
    with {:ok, contents} <- File.read(path),
         {:ok, identities} <- Jason.decode(contents) do
      parse(identities)
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:invalid_json, Exception.message(error)}}

      {:error, reason} ->
        {:error, {:file, path, reason}}
    end
  end

  defp load_file(path), do: {:error, {:invalid_path, path}}

  defp parse(identities) when is_list(identities) do
    case ParsedList.parse_indexed(identities, &parse_identity/1) do
      {:ok, identities} -> {:ok, identities}
      {:error, {index, reason}} -> {:error, {:identity, index, reason}}
    end
  end

  defp parse(_identities), do: {:error, :identities_must_be_a_list}

  defp parse_identity(%Identity{} = identity), do: {:ok, identity}

  defp parse_identity(value) when is_map(value) do
    with {:ok, issuer} <- fetch(value, :issuer),
         {:ok, subject} <- fetch(value, :subject),
         :ok <- validate_field(:issuer, issuer),
         :ok <- validate_field(:subject, subject) do
      {:ok, %Identity{issuer: issuer, subject: subject}}
    end
  end

  defp parse_identity(_value), do: {:error, :invalid_format}

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> map |> Map.fetch(Atom.to_string(key)) |> missing(key)
    end
  end

  defp missing(:error, key), do: {:error, {key, :missing}}
  defp missing({:ok, value}, _key), do: {:ok, value}

  defp validate_field(_field, value) when is_binary(value) and value != "", do: :ok
  defp validate_field(field, _value), do: {:error, {field, :invalid_format}}
end
