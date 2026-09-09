defmodule Biot.Protocol.Manifest do
  @moduledoc "A resolved environment manifest with a digest of its contents."

  alias Biot.Protocol.Digest
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

  defp encode_count(values), do: <<length(values)::unsigned-big-32>>

  defp encode_field(value) when is_binary(value) do
    [<<byte_size(value)::unsigned-big-32>>, value]
  end
end
