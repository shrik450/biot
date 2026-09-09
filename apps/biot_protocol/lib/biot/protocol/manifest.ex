defmodule Biot.Protocol.Manifest do
  @moduledoc "A resolved environment manifest with a digest of its contents."

  alias Biot.Protocol.Digest
  alias Biot.Protocol.ParsedList
  alias Biot.Protocol.PinnedSource
  alias Biot.Protocol.ProjectSnapshot

  @enforce_keys [:base_nixpkgs, :layers, :project_snapshot, :digest]
  defstruct [:base_nixpkgs, :layers, :project_snapshot, :digest]

  @type t :: %__MODULE__{
          base_nixpkgs: PinnedSource.t(),
          layers: [PinnedSource.t()],
          project_snapshot: ProjectSnapshot.t() | nil,
          digest: Digest.t()
        }

  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = manifest) do
    %{
      "base_nixpkgs" => PinnedSource.to_string(manifest.base_nixpkgs),
      "layers" => Enum.map(manifest.layers, &PinnedSource.to_string/1),
      "project_snapshot" => encode_project_snapshot(manifest.project_snapshot),
      "digest" => Digest.to_string(manifest.digest)
    }
  end

  @spec parse(term()) :: {:ok, t()} | {:error, atom()}
  def parse(value) when is_map(value) do
    with {:ok, base_nixpkgs} <- Map.fetch(value, "base_nixpkgs"),
         {:ok, base_nixpkgs} <- PinnedSource.parse(base_nixpkgs),
         {:ok, layers} <- Map.fetch(value, "layers"),
         {:ok, layers} <- ParsedList.parse(layers, &PinnedSource.parse/1),
         {:ok, project_snapshot} <- Map.fetch(value, "project_snapshot"),
         {:ok, project_snapshot} <- parse_project_snapshot(project_snapshot),
         {:ok, digest} <- Map.fetch(value, "digest"),
         {:ok, digest} <- Digest.parse(digest),
         manifest = %__MODULE__{
           base_nixpkgs: base_nixpkgs,
           layers: layers,
           project_snapshot: project_snapshot,
           digest: digest
         },
         true <- verify(manifest) do
      {:ok, manifest}
    else
      _error -> {:error, :invalid_format}
    end
  end

  def parse(_value), do: {:error, :invalid_format}

  @spec build(PinnedSource.t(), [PinnedSource.t()], ProjectSnapshot.t() | nil) :: t()
  def build(base_nixpkgs, layers, project_snapshot) do
    digest = Digest.compute(:manifest_v1, manifest_v1(base_nixpkgs, layers, project_snapshot))

    %__MODULE__{
      base_nixpkgs: base_nixpkgs,
      layers: layers,
      project_snapshot: project_snapshot,
      digest: digest
    }
  end

  @spec verify(t()) :: boolean()
  def verify(%__MODULE__{
        base_nixpkgs: base_nixpkgs,
        layers: layers,
        project_snapshot: project_snapshot,
        digest: digest
      }) do
    Digest.compute(:manifest_v1, manifest_v1(base_nixpkgs, layers, project_snapshot)) == digest
  end

  defp manifest_v1(base_nixpkgs, layers, project_snapshot) do
    [
      PinnedSource.canonical_fields(base_nixpkgs),
      encode_count(layers),
      encode_layers(layers),
      encode_snapshot(project_snapshot)
    ]
  end

  defp encode_layers(layers) do
    Enum.map(layers, &PinnedSource.canonical_fields/1)
  end

  defp encode_snapshot(nil), do: <<0>>

  defp encode_snapshot(%ProjectSnapshot{
         snapshot_id: snapshot_id,
         digest: %Digest{value: digest}
       }) do
    [<<1>>, encode_field(snapshot_id), encode_field(digest)]
  end

  defp parse_project_snapshot(nil), do: {:ok, nil}

  defp parse_project_snapshot(%{"snapshot_id" => snapshot_id, "digest" => digest})
       when is_binary(snapshot_id) and snapshot_id != "" do
    with {:ok, digest} <- Digest.parse(digest) do
      {:ok, %ProjectSnapshot{snapshot_id: snapshot_id, digest: digest}}
    end
  end

  defp parse_project_snapshot(_value), do: {:error, :invalid_format}

  defp encode_project_snapshot(nil), do: nil

  defp encode_project_snapshot(%ProjectSnapshot{} = snapshot) do
    %{
      "snapshot_id" => snapshot.snapshot_id,
      "digest" => Digest.to_string(snapshot.digest)
    }
  end

  defp encode_count(values), do: <<length(values)::unsigned-big-32>>

  defp encode_field(value) when is_binary(value) do
    [<<byte_size(value)::unsigned-big-32>>, value]
  end
end
