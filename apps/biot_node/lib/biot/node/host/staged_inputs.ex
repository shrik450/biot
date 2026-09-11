defmodule Biot.Node.Host.StagedInputs do
  @moduledoc """
  What one environment's fetch phase staged, parsed once from its `pins.json`.

  This is the whole contract between the two phases. Inspection asks whether it is still readable,
  the fetch phase turns it into the manifest the server sees, and the build phase takes its paths
  and hashes as the only inputs an evaluation may have. All three read the same parsed value, so
  none of them can decide on its own what a valid staging is.

  Parsing is strict at every level: a document, a build support entry, or a source with a key
  missing or a key too many is invalid, as is a path outside the store or a hash that is not
  Nix's. A staging the node can only half read is one it must do again, and a field it does not
  recognize is a contract it is not the one holding.
  """

  alias Biot.Node.StorePath
  alias Biot.Protocol.EnvironmentSelection
  alias Biot.Protocol.Manifest
  alias Biot.Protocol.NarHash
  alias Biot.Protocol.PinnedSource
  alias Biot.Protocol.StrictMap

  @fields ["build_support", "base_nixpkgs", "layers"]
  @input_fields ["store_path", "nar_hash"]
  @source_fields @input_fields ++ ["revision"]

  defmodule Input do
    @moduledoc "One staged store object: where it is, and the hash that names its bytes."

    alias Biot.Node.StorePath

    @enforce_keys [:store_path, :nar_hash]
    defstruct [:store_path, :nar_hash]

    @type t :: %__MODULE__{store_path: StorePath.t(), nar_hash: String.t()}
  end

  @enforce_keys [:build_support, :base_nixpkgs, :layers]
  defstruct [:build_support, :base_nixpkgs, :layers]

  @typedoc "One source's staged content and the revision it was pinned to."
  @type source :: %{input: Input.t(), revision: String.t()}

  @type t :: %__MODULE__{
          build_support: Input.t(),
          base_nixpkgs: source(),
          layers: [source()]
        }

  @doc "The entry name the fetch output gives each staged input, and the node gives each mount."
  @spec entries(t()) :: [{String.t(), Input.t()}]
  def entries(%__MODULE__{} = staged) do
    [
      {"build-support", staged.build_support},
      {"nixpkgs", staged.base_nixpkgs.input}
      | Enum.with_index(staged.layers, fn source, index -> {"layer-#{index}", source.input} end)
    ]
  end

  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_format}
  def parse(value) do
    with {:ok, value} <- StrictMap.fetch_exact(value, @fields),
         {:ok, build_support} <- parse_input(value["build_support"]),
         {:ok, base_nixpkgs} <- parse_source(value["base_nixpkgs"]),
         {:ok, layers} <- parse_sources(value["layers"]) do
      {:ok, %__MODULE__{build_support: build_support, base_nixpkgs: base_nixpkgs, layers: layers}}
    else
      _error -> {:error, :invalid_format}
    end
  end

  @doc """
  The manifest these staged inputs prove.

  Only the selection knows which selector each entry came from, so the pins become protocol values
  here rather than in the fetch output.
  """
  @spec manifest(t(), EnvironmentSelection.t()) :: {:ok, Manifest.t()} | {:error, :invalid_format}
  def manifest(%__MODULE__{} = staged, %EnvironmentSelection{} = selection) do
    with {:ok, base_nixpkgs} <- pin(selection.base_nixpkgs, staged.base_nixpkgs),
         {:ok, layers} <- pin_layers(selection.layers, staged.layers) do
      {:ok, Manifest.build(base_nixpkgs, layers, nil)}
    end
  end

  defp pin_layers(selectors, sources) when length(selectors) == length(sources) do
    selectors
    |> Enum.zip(sources)
    |> Enum.reduce_while({:ok, []}, fn {selector, source}, {:ok, pinned} ->
      case pin(selector, source) do
        {:ok, value} -> {:cont, {:ok, [value | pinned]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse()
  end

  defp pin_layers(_selectors, _sources), do: {:error, :invalid_format}

  defp pin(selector, %{input: input, revision: revision}) do
    case PinnedSource.pin(selector, revision, input.nar_hash) do
      {:ok, pinned} -> {:ok, pinned}
      {:error, _reason} -> {:error, :invalid_format}
    end
  end

  defp parse_sources(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, parsed} ->
      case parse_source(value) do
        {:ok, source} -> {:cont, {:ok, [source | parsed]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse()
  end

  # The revision's format has one owner, `PinnedSource.pin/3`, and `manifest/2` is the only thing
  # that uses the value; here it only has to be present and be text.
  defp parse_source(value) do
    with {:ok, value} <- StrictMap.fetch_exact(value, @source_fields),
         revision when is_binary(revision) <- value["revision"],
         {:ok, input} <- parse_input_fields(value) do
      {:ok, %{input: input, revision: revision}}
    else
      _error -> {:error, :invalid_format}
    end
  end

  defp parse_input(value) do
    with {:ok, value} <- StrictMap.fetch_exact(value, @input_fields) do
      parse_input_fields(value)
    end
  end

  defp parse_input_fields(value) do
    with {:ok, store_path} <- StorePath.parse(value["store_path"]),
         {:ok, nar_hash} <- NarHash.parse(value["nar_hash"]) do
      {:ok, %Input{store_path: store_path, nar_hash: nar_hash}}
    else
      _error -> {:error, :invalid_format}
    end
  end

  defp reverse({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse({:error, reason}), do: {:error, reason}
end
