defmodule Biot.Protocol.HostnameTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Biot.Protocol.Hostname
  alias Biot.Protocol.TestGenerators, as: Generators

  property "valid hostnames round-trip through their canonical string" do
    check all(hostname <- Generators.hostname()) do
      assert Hostname.parse(Hostname.to_string(hostname)) == {:ok, hostname}
      assert Kernel.to_string(hostname) == Hostname.to_string(hostname)
    end
  end

  test "parse accepts one-character and 63-character labels" do
    for value <- ["a", "0", "a-b", "a" <> String.duplicate("b", 61) <> "9"] do
      assert {:ok, hostname} = Hostname.parse(value)
      assert Hostname.to_string(hostname) == value
    end
  end

  test "parse rejects labels outside DNS length and hyphen rules" do
    invalid_values = [
      "",
      String.duplicate("a", 64),
      "-alpha",
      "alpha-",
      "Alpha",
      "alpha_beta",
      "alpha.beta",
      "alpha beta"
    ]

    for value <- invalid_values do
      assert Hostname.parse(value) == {:error, :invalid_format}
    end
  end
end
