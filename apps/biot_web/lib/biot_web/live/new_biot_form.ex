defmodule BiotWeb.Live.NewBiotForm do
  @moduledoc "Parses the creation form into protocol and server command values."

  alias Biot.Protocol.{
    AuthorizationValue,
    BiotName,
    EnvironmentSelection,
    NodeId,
    RepositorySource,
    SecretName,
    SecretValue,
    SourceSelector,
    Version
  }

  alias Biot.Server.Biots.Create

  @version Enum.max(Version.supported())

  @type runtime_secret :: %{name: SecretName.t(), value: SecretValue.t()}
  @type source_credential :: %{source: RepositorySource.t(), value: AuthorizationValue.t()}
  @type parsed :: %{
          command: Create.t(),
          final_state: :running | :stopped,
          runtime_secrets: [runtime_secret()],
          source_credentials: [source_credential()]
        }

  @spec parse(map()) :: {:ok, parsed()} | {:error, {:invalid_input, map()}}
  def parse(params) when is_map(params) do
    fields = %{
      repository: parse_required(params, "repository", &RepositorySource.parse/1),
      name: parse_required(params, "name", &BiotName.parse/1),
      node_id: parse_node(params),
      environment: parse_environment(params),
      initial_state: parse_initial_state(params),
      runtime_secrets: parse_runtime_secrets(Map.get(params, "runtime_secrets", %{})),
      source_credentials: parse_source_credentials(Map.get(params, "source_credentials", %{}))
    }

    errors =
      fields
      |> Enum.reduce(%{}, fn
        {field, {:error, reason}}, acc -> Map.put(acc, field, [reason])
        {_field, _value}, acc -> acc
      end)

    if errors != %{} do
      {:error, {:invalid_input, errors}}
    else
      {:ok, repository} = fields.repository
      {:ok, name} = fields.name
      {:ok, node_id} = fields.node_id
      {:ok, environment} = fields.environment
      {:ok, final_state} = fields.initial_state
      {:ok, runtime_secrets} = fields.runtime_secrets
      {:ok, source_credentials} = fields.source_credentials

      command_initial_state =
        if runtime_secrets != [] or source_credentials != [],
          do: :stopped,
          else: final_state

      {:ok,
       %{
         command: %Create{
           name: name,
           repository: repository,
           environment: environment,
           node_id: node_id,
           initial_state: command_initial_state
         },
         final_state: final_state,
         runtime_secrets: runtime_secrets,
         source_credentials: source_credentials
       }}
    end
  end

  def parse(_params), do: {:error, {:invalid_input, %{form: [:invalid_format]}}}

  @spec empty_layer(non_neg_integer()) :: map()
  def empty_layer(id), do: %{id: id, source: "", ref: ""}

  @spec empty_runtime_secret(non_neg_integer()) :: map()
  def empty_runtime_secret(id), do: %{id: id, name: ""}

  @spec empty_source_credential(non_neg_integer()) :: map()
  def empty_source_credential(id), do: %{id: id, source: ""}

  defp parse_required(params, key, parser) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> parser.(value)
      _missing -> {:error, :missing}
    end
  end

  defp parse_node(params) do
    case Map.get(params, "node_id", "") do
      value when value in ["", "default", "server picks"] -> {:ok, :default}
      value when is_binary(value) -> NodeId.parse(value)
      _value -> {:error, :invalid_format}
    end
  end

  defp parse_environment(params) do
    with {:ok, base_nixpkgs} <-
           parse_selector(Map.get(params, "base_source", ""), Map.get(params, "base_ref", "")),
         {:ok, layers} <- parse_layers(Map.get(params, "layers", %{})) do
      EnvironmentSelection.parse(%{
        "base_nixpkgs" => SourceSelector.to_string(base_nixpkgs),
        "layers" => Enum.map(layers, &SourceSelector.to_string/1)
      })
    end
  end

  defp parse_selector("nixpkgs", ""), do: {:ok, SourceSelector.nixpkgs()}

  defp parse_selector(source, ref) when is_binary(source) and is_binary(ref) do
    with {:ok, repository} <- RepositorySource.parse(source),
         do: SourceSelector.new(repository, ref)
  end

  defp parse_selector(_source, _ref), do: {:error, :invalid_format}

  defp parse_layers(params) do
    params
    |> rows()
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, layers} ->
      case parse_layer_row(row) do
        :skip -> {:cont, {:ok, layers}}
        {:ok, selector} -> {:cont, {:ok, layers ++ [selector]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_layer_row(row) do
    case row_values(row, ["source", "ref"]) do
      {:ok, ["", ""]} -> :skip
      {:ok, [source, ref]} -> parse_selector(source, ref)
      :error -> {:error, :invalid_format}
    end
  end

  defp parse_initial_state(params) do
    case Map.get(params, "initial_state", "running") do
      "running" -> {:ok, :running}
      "stopped" -> {:ok, :stopped}
      _value -> {:error, :invalid_format}
    end
  end

  defp parse_runtime_secrets(params) do
    params
    |> rows()
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, secrets} ->
      case parse_runtime_secret_row(row) do
        :skip -> {:cont, {:ok, secrets}}
        {:ok, secret} -> {:cont, {:ok, secrets ++ [secret]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_runtime_secret_row(row) do
    case row_values(row, ["name", "value"]) do
      {:ok, ["", ""]} ->
        :skip

      {:ok, [name, value]} ->
        with {:ok, name} <- SecretName.parse(name),
             {:ok, value} <- SecretValue.parse(value, @version) do
          {:ok, %{name: name, value: value}}
        end

      :error ->
        {:error, :invalid_format}
    end
  end

  defp parse_source_credentials(params) do
    params
    |> rows()
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, credentials} ->
      case parse_source_credential_row(row) do
        :skip -> {:cont, {:ok, credentials}}
        {:ok, credential} -> {:cont, {:ok, credentials ++ [credential]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_source_credential_row(row) do
    case row_values(row, ["source", "value"]) do
      {:ok, ["", ""]} ->
        :skip

      {:ok, [source, value]} ->
        with {:ok, source} <- RepositorySource.parse(source),
             {:ok, value} <- AuthorizationValue.parse(value, @version) do
          {:ok, %{source: source, value: value}}
        end

      :error ->
        {:error, :invalid_format}
    end
  end

  defp row_values(row, keys) when is_map(row),
    do: {:ok, Enum.map(keys, &Map.get(row, &1, ""))}

  defp row_values(_row, _keys), do: :error

  defp rows(params) when is_list(params), do: params

  defp rows(params) when is_map(params) do
    params
    |> Enum.sort_by(fn {key, _value} -> row_index(key) end)
    |> Enum.map(fn {_key, value} -> value end)
  end

  defp rows(_params), do: []

  defp row_index(key) do
    case Integer.parse(to_string(key)) do
      {index, ""} -> {0, index}
      _other -> {1, to_string(key)}
    end
  end
end
