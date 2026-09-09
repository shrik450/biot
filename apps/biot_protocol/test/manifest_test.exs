defmodule Biot.Protocol.ManifestTest do
  use ExUnit.Case, async: true

  alias Biot.Protocol.Digest
  alias Biot.Protocol.Manifest
  alias Biot.Protocol.PinnedSource
  alias Biot.Protocol.ProjectSnapshot
  alias Biot.Protocol.RepositorySource
  alias Biot.Protocol.SourceSelector

  @revision_a String.duplicate("a", 40)
  @revision_b String.duplicate("b", 40)
  @revision_c String.duplicate("c", 40)
  @nar_a "sha256-" <> Base.encode64(:binary.copy(<<1>>, 32))
  @nar_b "sha256-" <> Base.encode64(:binary.copy(<<2>>, 32))
  @nar_c "sha256-" <> Base.encode64(:binary.copy(<<3>>, 32))

  setup_all do
    {:ok, base} = PinnedSource.pin(SourceSelector.nixpkgs(), @revision_a, @nar_a)
    {:ok, other_base} = PinnedSource.pin(SourceSelector.nixpkgs(), @revision_b, @nar_b)
    {:ok, layer_a} = pinned_git("https://github.com/example/a.git", @revision_a, @nar_a)
    {:ok, layer_b} = pinned_git("https://github.com/example/b.git", @revision_b, @nar_b)
    {:ok, layer_c} = pinned_git("https://github.com/example/c.git", @revision_c, @nar_c)

    snapshot = %ProjectSnapshot{
      snapshot_id: "snapshot-a",
      digest: Digest.compute(:project_snapshot_v1, "snapshot bytes a")
    }

    other_snapshot = %ProjectSnapshot{
      snapshot_id: "snapshot-b",
      digest: Digest.compute(:project_snapshot_v1, "snapshot bytes b")
    }

    %{
      base: base,
      other_base: other_base,
      layer_a: layer_a,
      layer_b: layer_b,
      layer_c: layer_c,
      snapshot: snapshot,
      other_snapshot: other_snapshot
    }
  end

  test "build is deterministic for the same manifest fields", context do
    first = Manifest.build(context.base, [context.layer_a, context.layer_b], context.snapshot)
    second = Manifest.build(context.base, [context.layer_a, context.layer_b], context.snapshot)

    assert first == second
    assert Manifest.verify(first)
  end

  test "changing one manifest field changes its digest", context do
    original = Manifest.build(context.base, [context.layer_a, context.layer_b], context.snapshot)

    changed_manifests = [
      Manifest.build(context.other_base, [context.layer_a, context.layer_b], context.snapshot),
      Manifest.build(context.base, [context.layer_a, context.layer_c], context.snapshot),
      Manifest.build(context.base, [context.layer_b, context.layer_a], context.snapshot),
      Manifest.build(context.base, [context.layer_a, context.layer_b], nil),
      Manifest.build(context.base, [context.layer_a, context.layer_b], context.other_snapshot)
    ]

    for changed <- changed_manifests do
      refute changed.digest == original.digest
    end
  end

  test "adding or removing a layer changes the digest", context do
    without_layers = Manifest.build(context.base, [], nil)
    one_layer = Manifest.build(context.base, [context.layer_a], nil)
    two_layers = Manifest.build(context.base, [context.layer_a, context.layer_b], nil)

    refute without_layers.digest == one_layer.digest
    refute one_layer.digest == two_layers.digest
  end

  test "verify rejects every altered manifest field", context do
    manifest = Manifest.build(context.base, [context.layer_a, context.layer_b], context.snapshot)

    altered_manifests = [
      %{manifest | base_nixpkgs: context.other_base},
      %{manifest | layers: [context.layer_a, context.layer_c]},
      %{manifest | layers: Enum.reverse(manifest.layers)},
      %{manifest | project_snapshot: nil},
      %{manifest | project_snapshot: context.other_snapshot},
      %{manifest | digest: Digest.compute(:manifest_v1, "not this manifest")}
    ]

    for altered <- altered_manifests do
      refute Manifest.verify(altered)
    end
  end

  test "snapshot ID and digest each affect the manifest digest", context do
    original = Manifest.build(context.base, [], context.snapshot)

    changed_id =
      Manifest.build(context.base, [], %{context.snapshot | snapshot_id: "snapshot-changed"})

    changed_digest =
      Manifest.build(context.base, [], %{
        context.snapshot
        | digest: Digest.compute(:project_snapshot_v1, "changed bytes")
      })

    refute changed_id.digest == original.digest
    refute changed_digest.digest == original.digest
  end

  defp pinned_git(url, revision, nar_hash) do
    with {:ok, repository} <- RepositorySource.parse(url),
         {:ok, selector} <- SourceSelector.new(repository, "main") do
      PinnedSource.pin(selector, revision, nar_hash)
    end
  end
end
