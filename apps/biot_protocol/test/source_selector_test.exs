defmodule Biot.Protocol.SourceSelectorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Biot.Protocol.RepositorySource
  alias Biot.Protocol.SourceSelector
  alias Biot.Protocol.TestGenerators, as: Generators

  property "source selectors round-trip through their canonical string" do
    check all(selector <- Generators.source_selector()) do
      assert SourceSelector.parse(SourceSelector.to_string(selector)) == {:ok, selector}
      assert Kernel.to_string(selector) == SourceSelector.to_string(selector)
    end
  end

  test "nixpkgs has one exact canonical spelling" do
    selector = SourceSelector.nixpkgs()

    assert SourceSelector.parse("nixpkgs") == {:ok, selector}
    assert SourceSelector.to_string(selector) == "nixpkgs"

    for value <- ["NIXPKGS", "nixpkgs#", " nixpkgs", "nixpkgs\n"] do
      assert SourceSelector.parse(value) == {:error, :invalid_format}
    end
  end

  test "new accepts a parsed repository" do
    assert {:ok, repository} = RepositorySource.parse("https://github.com/example/project.git")

    assert {:ok, _selector} = SourceSelector.new(repository, "main")
  end

  test "parse and new reject invalid refs" do
    url = "https://github.com/example/project.git"
    assert {:ok, repository} = RepositorySource.parse(url)

    invalid_refs = ["", "-main", "feature..next", "feature#next", "feature next", "main\n"]

    for ref <- invalid_refs do
      assert SourceSelector.new(repository, ref) == {:error, :invalid_format}
      assert SourceSelector.parse(url <> "#" <> ref) == {:error, :invalid_format}
    end
  end

  test "parse reports repository credential errors" do
    assert SourceSelector.parse("https://user@github.com/example/project.git#main") ==
             {:error, :embedded_credentials}
  end
end
