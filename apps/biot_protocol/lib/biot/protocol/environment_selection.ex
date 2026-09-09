defmodule Biot.Protocol.EnvironmentSelection do
  @moduledoc "The source selection used to define an environment."

  alias Biot.Protocol.Limits
  alias Biot.Protocol.ParsedList
  alias Biot.Protocol.RelativeDirectory
  alias Biot.Protocol.SourceSelector

  alias Biot.Protocol.StrictMap

  @fields ["base_nixpkgs", "layers", "project_context"]

  @enforce_keys [:base_nixpkgs, :layers, :project_context]
  defstruct [:base_nixpkgs, :layers, :project_context]

  @type t :: %__MODULE__{
          base_nixpkgs: SourceSelector.t(),
          layers: [SourceSelector.t()],
          project_context: RelativeDirectory.t() | nil
        }

  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = selection) do
    %{
      "base_nixpkgs" => SourceSelector.to_string(selection.base_nixpkgs),
      "layers" => Enum.map(selection.layers, &SourceSelector.to_string/1),
      "project_context" => encode_project_context(selection.project_context)
    }
  end

  @spec parse(term()) ::
          {:ok, t()}
          | {:error,
             :invalid_format
             | :embedded_credentials
             | :repository_url_too_long
             | :source_ref_too_long
             | :absolute_path
             | :parent_segment
             | :directory_too_long
             | :too_many_layers}
  def parse(value) when is_map(value) do
    with {:ok, value} <- StrictMap.fetch_exact(value, @fields),
         {:ok, base_nixpkgs} <- Map.fetch(value, "base_nixpkgs"),
         {:ok, base_nixpkgs} <- SourceSelector.parse(base_nixpkgs),
         {:ok, layers} <- Map.fetch(value, "layers"),
         :ok <- check_layer_count(layers),
         {:ok, layers} <- ParsedList.parse(layers, &SourceSelector.parse/1),
         {:ok, project_context} <- Map.fetch(value, "project_context"),
         {:ok, project_context} <- parse_project_context(project_context) do
      {:ok,
       %__MODULE__{
         base_nixpkgs: base_nixpkgs,
         layers: layers,
         project_context: project_context
       }}
    else
      :error -> {:error, :invalid_format}
      {:error, reason} -> {:error, reason}
    end
  end

  def parse(_value), do: {:error, :invalid_format}

  defp check_layer_count(layers) when is_list(layers) do
    if length(layers) <= Limits.max_layers(), do: :ok, else: {:error, :too_many_layers}
  end

  defp check_layer_count(_layers), do: {:error, :invalid_format}

  defp parse_project_context(nil), do: {:ok, nil}
  defp parse_project_context(value), do: RelativeDirectory.parse(value)

  defp encode_project_context(nil), do: nil
  defp encode_project_context(value), do: RelativeDirectory.to_string(value)
end
