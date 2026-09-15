defmodule Biot.Protocol.Manifest do
  @moduledoc "A resolved environment manifest with a digest of its contents."

  alias Biot.Protocol.Digest
  alias Biot.Protocol.ParsedList
  alias Biot.Protocol.PinnedSource
  alias Biot.Protocol.Platform
  alias Biot.Protocol.StrictMap

  @fields ["platform", "base_nixpkgs", "layers", "digest"]

  @enforce_keys [:platform, :base_nixpkgs, :layers, :digest]
  defstruct [:platform, :base_nixpkgs, :layers, :digest]

  @type t :: %__MODULE__{
          platform: Platform.t(),
          base_nixpkgs: PinnedSource.t(),
          layers: [PinnedSource.t()],
          digest: Digest.t()
        }

  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = manifest) do
    %{
      "platform" => Platform.to_string(manifest.platform),
      "base_nixpkgs" => PinnedSource.to_string(manifest.base_nixpkgs),
      "layers" => Enum.map(manifest.layers, &PinnedSource.to_string/1),
      "digest" => Digest.to_string(manifest.digest)
    }
  end

  @spec parse(term()) :: {:ok, t()} | {:error, atom()}
  def parse(value) when is_map(value) do
    with {:ok, value} <- StrictMap.fetch_exact(value, @fields),
         {:ok, platform} <- Platform.parse(value["platform"]),
         {:ok, base_nixpkgs} <- PinnedSource.parse(value["base_nixpkgs"]),
         {:ok, layers} <- ParsedList.parse(value["layers"], &PinnedSource.parse/1),
         {:ok, digest} <- Digest.parse(value["digest"]),
         manifest = %__MODULE__{
           platform: platform,
           base_nixpkgs: base_nixpkgs,
           layers: layers,
           digest: digest
         },
         true <- verify(manifest) do
      {:ok, manifest}
    else
      _error -> {:error, :invalid_format}
    end
  end

  def parse(_value), do: {:error, :invalid_format}

  @spec build(Platform.t(), PinnedSource.t(), [PinnedSource.t()]) :: t()
  def build(platform, base_nixpkgs, layers) do
    %__MODULE__{
      platform: platform,
      base_nixpkgs: base_nixpkgs,
      layers: layers,
      digest: compute_digest(platform, base_nixpkgs, layers)
    }
  end

  @spec verify(t()) :: boolean()
  def verify(%__MODULE__{} = manifest) do
    compute_digest(manifest.platform, manifest.base_nixpkgs, manifest.layers) == manifest.digest
  end

  defp compute_digest(platform, base_nixpkgs, layers) do
    Digest.compute(:manifest_v1, [
      encode_field(Platform.to_string(platform)),
      PinnedSource.canonical_fields(base_nixpkgs),
      <<length(layers)::unsigned-big-32>>,
      Enum.map(layers, &PinnedSource.canonical_fields/1)
    ])
  end

  defp encode_field(value), do: [<<byte_size(value)::unsigned-big-32>>, value]
end
