defmodule Biot.Protocol.BiotNameTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Biot.Protocol.BiotName
  alias Biot.Protocol.CanonicalUuid

  test "a lowercase DNS label round-trips" do
    for value <- ["a", "9", "checkout-flow", "api2", String.duplicate("a", 63)] do
      assert {:ok, name} = BiotName.parse(value)
      assert BiotName.to_string(name) == value
      assert Kernel.to_string(name) == value
    end
  end

  test "anything that is not a lowercase DNS label is rejected" do
    for value <- [
          "",
          "-api",
          "api-",
          "Api",
          "my api",
          "api/web",
          "api.web",
          "api_web",
          "api\n",
          "café",
          String.duplicate("a", 64),
          nil,
          :api,
          7
        ] do
      assert BiotName.parse(value) == {:error, :invalid_format}
    end
  end

  test "a canonical UUID is not a name, so a client can tell names from Biot IDs" do
    assert BiotName.parse(CanonicalUuid.generate()) == {:error, :invalid_format}
    assert {:ok, _name} = BiotName.parse("0123abcd-0123")
  end

  property "parse never raises and accepts only what the DNS label rule accepts" do
    check all(value <- StreamData.string(:printable, max_length: 70)) do
      expected = Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/, value)

      case BiotName.parse(value) do
        {:ok, name} ->
          assert expected and BiotName.to_string(name) == value

        {:error, :invalid_format} ->
          refute expected and CanonicalUuid.parse(value) != {:ok, value}
      end
    end
  end
end
