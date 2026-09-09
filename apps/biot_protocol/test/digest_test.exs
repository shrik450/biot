defmodule Biot.Protocol.DigestTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Biot.Protocol.Digest
  alias Biot.Protocol.TestGenerators, as: Generators

  property "digests round-trip through lowercase hexadecimal text" do
    check all(digest <- Generators.digest()) do
      assert Digest.parse(Digest.to_string(digest)) == {:ok, digest}
      assert Kernel.to_string(digest) == Digest.to_string(digest)
    end
  end

  test "parse accepts exactly 64 lowercase hexadecimal digits" do
    valid = String.duplicate("ab", 32)

    assert {:ok, digest} = Digest.parse(valid)
    assert Digest.to_string(digest) == valid

    for invalid <- [
          String.duplicate("a", 63),
          String.duplicate("a", 65),
          String.duplicate("A", 64),
          String.duplicate("g", 64),
          valid <> "\n"
        ] do
      assert Digest.parse(invalid) == {:error, :invalid_format}
    end
  end

  test "compute is deterministic and reads iodata as bytes" do
    assert Digest.compute(:example_v1, ["same", " bytes"]) ==
             Digest.compute(:example_v1, "same bytes")
  end

  test "compute changes when the bytes change" do
    refute Digest.compute(:example_v1, "bytes-a") == Digest.compute(:example_v1, "bytes-b")
  end

  test "compute separates encoding names for the same bytes" do
    refute Digest.compute(:example_v1, "same bytes") ==
             Digest.compute(:example_v2, "same bytes")
  end
end
