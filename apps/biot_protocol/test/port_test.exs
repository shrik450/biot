defmodule Biot.Protocol.PortTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Biot.Protocol.Port
  alias Biot.Protocol.TestGenerators, as: Generators

  property "ports round-trip through canonical decimal text" do
    check all(port <- Generators.port()) do
      assert Port.parse(Port.to_string(port)) == {:ok, port}
      assert Kernel.to_string(port) == Port.to_string(port)
    end
  end

  test "parse accepts both boundary ports as integers and canonical strings" do
    for value <- [1, 65_535] do
      assert {:ok, port} = Port.parse(value)
      assert Port.parse(Integer.to_string(value)) == {:ok, port}
    end
  end

  test "parse reports values outside the port range" do
    for value <- [0, 65_536, -1, "0", "65536"] do
      assert Port.parse(value) == {:error, :out_of_range}
    end
  end

  test "parse rejects non-canonical decimal strings" do
    for value <- ["", "01", "0001", "+1", "-1", "1.0", " 1", "1 ", "1\n"] do
      assert Port.parse(value) == {:error, :invalid_format}
    end
  end
end
