defmodule Biot.Server.Publications.HostnameTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Biot.Protocol.Hostname
  alias Biot.Server.Publications.Hostname, as: Allocation

  @base32_alphabet ~c"abcdefghijklmnopqrstuvwxyz234567"

  property "every allocated label is a 26-character lowercase base32 hostname" do
    check all(_iteration <- StreamData.constant(:allocate), max_runs: 200) do
      hostname = Allocation.allocate()

      assert {:ok, ^hostname} = Hostname.parse(hostname.value)
      assert String.length(hostname.value) == 26

      for character <- String.to_charlist(hostname.value) do
        assert character in @base32_alphabet,
               "unexpected character #{inspect(character)} in #{hostname.value}"
      end
    end
  end

  test "two allocations differ" do
    labels = Enum.map(1..500, fn _index -> Allocation.allocate().value end)

    assert length(Enum.uniq(labels)) == 500
  end
end
