defmodule Biot.Protocol.ManifestTest do
  use ExUnit.Case, async: true

  alias Biot.Protocol.Digest
  alias Biot.Protocol.Manifest
  alias Biot.Protocol.PinnedSource
  alias Biot.Protocol.Platform
  alias Biot.Protocol.RepositorySource
  alias Biot.Protocol.SourceSelector

  @revision_a String.duplicate("a", 40)
  @revision_b String.duplicate("b", 40)
  @revision_c String.duplicate("c", 40)
  @nar_a "sha256-" <> Base.encode64(:binary.copy(<<1>>, 32))
  @nar_b "sha256-" <> Base.encode64(:binary.copy(<<2>>, 32))
  @nar_c "sha256-" <> Base.encode64(:binary.copy(<<3>>, 32))

  setup_all do
    {:ok, x86} = Platform.parse("x86_64-linux")
    {:ok, arm} = Platform.parse("aarch64-linux")
    {:ok, base} = PinnedSource.pin(SourceSelector.nixpkgs(), @revision_a, @nar_a)
    {:ok, other_base} = PinnedSource.pin(SourceSelector.nixpkgs(), @revision_b, @nar_b)
    {:ok, layer_a} = pinned_git("https://github.com/example/a.git", @revision_a, @nar_a)
    {:ok, layer_b} = pinned_git("https://github.com/example/b.git", @revision_b, @nar_b)
    {:ok, layer_c} = pinned_git("https://github.com/example/c.git", @revision_c, @nar_c)

    %{
      x86: x86,
      arm: arm,
      base: base,
      other_base: other_base,
      layer_a: layer_a,
      layer_b: layer_b,
      layer_c: layer_c
    }
  end

  test "build is deterministic for the same manifest fields", context do
    first = Manifest.build(context.x86, context.base, [context.layer_a, context.layer_b])
    second = Manifest.build(context.x86, context.base, [context.layer_a, context.layer_b])

    assert first == second
    assert Manifest.verify(first)
  end

  test "changing one manifest field changes its digest", context do
    original = Manifest.build(context.x86, context.base, [context.layer_a, context.layer_b])

    changed_manifests = [
      Manifest.build(context.arm, context.base, [context.layer_a, context.layer_b]),
      Manifest.build(context.x86, context.other_base, [context.layer_a, context.layer_b]),
      Manifest.build(context.x86, context.base, [context.layer_a, context.layer_c]),
      Manifest.build(context.x86, context.base, [context.layer_b, context.layer_a])
    ]

    for changed <- changed_manifests do
      refute changed.digest == original.digest
    end
  end

  test "adding or removing a layer changes the digest", context do
    without_layers = Manifest.build(context.x86, context.base, [])
    one_layer = Manifest.build(context.x86, context.base, [context.layer_a])
    two_layers = Manifest.build(context.x86, context.base, [context.layer_a, context.layer_b])

    refute without_layers.digest == one_layer.digest
    refute one_layer.digest == two_layers.digest
  end

  test "verify rejects every altered manifest field", context do
    manifest = Manifest.build(context.x86, context.base, [context.layer_a, context.layer_b])

    altered_manifests = [
      %{manifest | platform: context.arm},
      %{manifest | base_nixpkgs: context.other_base},
      %{manifest | layers: [context.layer_a, context.layer_c]},
      %{manifest | layers: Enum.reverse(manifest.layers)},
      %{manifest | digest: Digest.compute(:manifest_v1, "not this manifest")}
    ]

    for altered <- altered_manifests do
      refute Manifest.verify(altered)
    end
  end

  test "parse accepts only an encoding whose digest matches its fields", context do
    manifest = Manifest.build(context.x86, context.base, [context.layer_a])
    encoded = Manifest.encode(manifest)

    assert Manifest.parse(encoded) == {:ok, manifest}
    assert Manifest.parse(%{encoded | "platform" => "aarch64-linux"}) == {:error, :invalid_format}
    assert Manifest.parse(Map.delete(encoded, "platform")) == {:error, :invalid_format}
  end

  defp pinned_git(url, revision, nar_hash) do
    with {:ok, repository} <- RepositorySource.parse(url),
         {:ok, selector} <- SourceSelector.new(repository, "main") do
      PinnedSource.pin(selector, revision, nar_hash)
    end
  end
end
