defmodule Biot.Protocol.RelativeDirectoryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Biot.Protocol.RelativeDirectory
  alias Biot.Protocol.TestGenerators, as: Generators

  property "relative directories round-trip through their path" do
    check all(directory <- Generators.relative_directory()) do
      assert RelativeDirectory.parse(RelativeDirectory.to_string(directory)) == {:ok, directory}
      assert Kernel.to_string(directory) == RelativeDirectory.to_string(directory)
    end
  end

  test "parse preserves a nested relative directory" do
    assert {:ok, directory} = RelativeDirectory.parse("apps/web/assets")
    assert RelativeDirectory.to_string(directory) == "apps/web/assets"
  end

  test "parse rejects absolute paths before empty-segment errors" do
    for path <- ["/", "/apps", "/apps/web"] do
      assert RelativeDirectory.parse(path) == {:error, :absolute_path}
    end
  end

  test "parse rejects parent segments wherever they appear" do
    for path <- ["..", "../apps", "apps/../web", "apps/.."] do
      assert RelativeDirectory.parse(path) == {:error, :parent_segment}
    end
  end

  test "parse rejects dot, empty, repeated, and trailing segments" do
    for path <- ["", ".", "./apps", "apps/./web", "apps/.", "apps//web", "apps/"] do
      assert RelativeDirectory.parse(path) == {:error, :invalid_format}
    end
  end

  test "parse rejects invalid UTF-8 and null bytes" do
    for path <- [<<255>>, "apps/" <> <<0>> <> "web"] do
      assert RelativeDirectory.parse(path) == {:error, :invalid_format}
    end
  end
end
