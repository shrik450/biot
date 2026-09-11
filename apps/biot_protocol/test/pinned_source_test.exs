defmodule Biot.Protocol.PinnedSourceTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Biot.Protocol.PinnedSource
  alias Biot.Protocol.RepositorySource
  alias Biot.Protocol.SourceSelector
  alias Biot.Protocol.TestGenerators, as: Generators

  @revision String.duplicate("a", 40)
  @other_revision String.duplicate("b", 40)
  @nar_hash "sha256-" <> Base.encode64(:binary.copy(<<1>>, 32))
  @other_nar_hash "sha256-" <> Base.encode64(:binary.copy(<<2>>, 32))

  property "pinned sources round-trip through their canonical string" do
    check all(pinned_source <- Generators.pinned_source()) do
      assert PinnedSource.parse(PinnedSource.to_string(pinned_source)) == {:ok, pinned_source}
      assert Kernel.to_string(pinned_source) == PinnedSource.to_string(pinned_source)
    end
  end

  test "pin keeps revision before NAR hash in nixpkgs text" do
    assert {:ok, pinned_source} =
             PinnedSource.pin(SourceSelector.nixpkgs(), @revision, @nar_hash)

    assert PinnedSource.to_string(pinned_source) ==
             Enum.join(["nixpkgs", @revision, @nar_hash], "#")
  end

  test "pin keeps repository, revision, and NAR hash in git text" do
    url = "https://github.com/example/project.git"
    assert {:ok, repository} = RepositorySource.parse(url)
    assert {:ok, selector} = SourceSelector.new(repository, "main")
    assert {:ok, pinned_source} = PinnedSource.pin(selector, @revision, @nar_hash)

    assert PinnedSource.to_string(pinned_source) == Enum.join([url, @revision, @nar_hash], "#")
  end

  test "pin replaces a selector ref with the resolved revision" do
    assert {:ok, repository} = RepositorySource.parse("https://github.com/example/project.git")
    assert {:ok, main} = SourceSelector.new(repository, "main")
    assert {:ok, feature} = SourceSelector.new(repository, "feature")

    assert PinnedSource.pin(main, @revision, @nar_hash) ==
             PinnedSource.pin(feature, @revision, @nar_hash)
  end

  test "parse and pin require exactly 40 lowercase hexadecimal revision digits" do
    invalid_revisions = [
      String.duplicate("a", 39),
      String.duplicate("a", 41),
      String.duplicate("A", 40),
      String.duplicate("g", 40),
      @revision <> "\n"
    ]

    for revision <- invalid_revisions do
      assert PinnedSource.pin(SourceSelector.nixpkgs(), revision, @nar_hash) ==
               {:error, :invalid_format}

      assert PinnedSource.parse(Enum.join(["nixpkgs", revision, @nar_hash], "#")) ==
               {:error, :invalid_format}
    end
  end

  test "parse and pin require a canonical SHA-256 NAR hash" do
    invalid_hashes = [
      Base.encode64(:binary.copy(<<1>>, 32)),
      "sha512-" <> Base.encode64(:binary.copy(<<1>>, 32)),
      "sha256-" <> Base.encode64(:binary.copy(<<1>>, 31)),
      "sha256-" <> Base.encode64(:binary.copy(<<1>>, 33)),
      "sha256-not-base64",
      "sha256-" <> Base.encode64(:binary.copy(<<1>>, 32), padding: false)
    ]

    for nar_hash <- invalid_hashes do
      assert PinnedSource.pin(SourceSelector.nixpkgs(), @revision, nar_hash) ==
               {:error, :invalid_format}

      assert PinnedSource.parse(Enum.join(["nixpkgs", @revision, nar_hash], "#")) ==
               {:error, :invalid_format}
    end
  end

  test "parse rejects missing, extra, and swapped fields" do
    invalid_values = [
      "nixpkgs",
      Enum.join(["nixpkgs", @revision], "#"),
      Enum.join(["nixpkgs", @revision, @nar_hash, "extra"], "#"),
      Enum.join(["nixpkgs", @nar_hash, @revision], "#"),
      Enum.join(["nixpkgs", @other_revision, @other_nar_hash, ""], "#")
    ]

    for value <- invalid_values do
      assert PinnedSource.parse(value) == {:error, :invalid_format}
    end
  end

  test "parse reports repository credential errors" do
    value = Enum.join(["https://user@github.com/example/project.git", @revision, @nar_hash], "#")
    assert PinnedSource.parse(value) == {:error, :embedded_credentials}
  end

  test "pin accepts a parsed HTTPS selector" do
    assert {:ok, repository} =
             RepositorySource.parse("https://github.com/example/project.git")

    assert {:ok, selector} = SourceSelector.new(repository, "main")
    assert {:ok, _pinned_source} = PinnedSource.pin(selector, @revision, @nar_hash)
  end
end
