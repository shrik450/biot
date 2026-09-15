defmodule Biot.Protocol.EnvironmentSelection do
  @moduledoc "The source selection used to define an environment."

  alias Biot.Protocol.Limits
  alias Biot.Protocol.ParsedList
  alias Biot.Protocol.SourceSelector

  alias Biot.Protocol.StrictMap

  @fields ["base_nixpkgs", "layers"]

  @enforce_keys [:base_nixpkgs, :layers]
  defstruct [:base_nixpkgs, :layers]

  @type t :: %__MODULE__{
          base_nixpkgs: SourceSelector.t(),
          layers: [SourceSelector.t()]
        }

  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = selection) do
    %{
      "base_nixpkgs" => SourceSelector.to_string(selection.base_nixpkgs),
      "layers" => Enum.map(selection.layers, &SourceSelector.to_string/1)
    }
  end

  @spec parse(term()) ::
          {:ok, t()}
          | {:error,
             :invalid_format
             | :embedded_credentials
             | :repository_url_too_long
             | :source_ref_too_long
             | :too_many_layers}
  def parse(value) when is_map(value) do
    with {:ok, value} <- StrictMap.fetch_exact(value, @fields),
         {:ok, base_nixpkgs} <- Map.fetch(value, "base_nixpkgs"),
         {:ok, base_nixpkgs} <- SourceSelector.parse(base_nixpkgs),
         {:ok, layers} <- Map.fetch(value, "layers"),
         :ok <- check_layer_count(layers),
         {:ok, layers} <- ParsedList.parse(layers, &SourceSelector.parse/1) do
      {:ok, %__MODULE__{base_nixpkgs: base_nixpkgs, layers: layers}}
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
end
