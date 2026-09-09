defmodule Biot.Node.DiagnosticsIntegrationTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Biot.Node.Diagnostics
  alias Biot.Protocol.BiotId

  @stored_limit 65_536
  @entry_limit 5

  setup do
    biot_id = id()
    on_exit(fn -> Diagnostics.forget(biot_id) end)
    %{biot_id: biot_id}
  end

  test "fetch bounds content and reports truncation from either bound", %{biot_id: biot_id} do
    exact = Diagnostics.put(biot_id, 1, "0123456789")
    assert Diagnostics.fetch(exact, 10) == {:ok, {"0123456789", false}}
    assert Diagnostics.fetch(exact, 4) == {:ok, {"0123", true}}

    oversized = Diagnostics.put(biot_id, 2, :binary.copy("a", @stored_limit + 1))
    assert {:ok, {content, true}} = Diagnostics.fetch(oversized, @stored_limit + 100)
    assert byte_size(content) == @stored_limit
  end

  test "only the latest failed attempt for one revision remains", %{biot_id: biot_id} do
    first = Diagnostics.put(biot_id, 4, "first attempt")
    second = Diagnostics.put(biot_id, 4, "second attempt")

    assert Diagnostics.fetch(first, 100) == :not_found
    assert Diagnostics.fetch(second, 100) == {:ok, {"second attempt", false}}
  end

  test "old revisions are evicted without affecting another biot", %{biot_id: biot_id} do
    other_biot = id()
    on_exit(fn -> Diagnostics.forget(other_biot) end)
    other = Diagnostics.put(other_biot, 1, "other")

    entries =
      for revision <- 1..(@entry_limit + 1),
          do: Diagnostics.put(biot_id, revision, "r#{revision}")

    assert Diagnostics.fetch(hd(entries), 100) == :not_found

    for {entry, revision} <- Enum.zip(tl(entries), 2..(@entry_limit + 1)) do
      assert Diagnostics.fetch(entry, 100) == {:ok, {"r#{revision}", false}}
    end

    assert Diagnostics.fetch(other, 100) == {:ok, {"other", false}}
  end

  test "forget makes every diagnostic for the biot unavailable", %{biot_id: biot_id} do
    entries = for revision <- 1..3, do: Diagnostics.put(biot_id, revision, "r#{revision}")
    assert :ok = Diagnostics.forget(biot_id)
    assert Enum.all?(entries, &(Diagnostics.fetch(&1, 100) == :not_found))
  end

  defp id do
    {:ok, id} = BiotId.parse(Ecto.UUID.generate())
    id
  end
end
