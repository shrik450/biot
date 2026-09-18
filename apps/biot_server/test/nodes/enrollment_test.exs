defmodule Biot.Server.Nodes.EnrollmentTest do
  use ExUnit.Case, async: true

  alias Biot.Server.Nodes.Enrollment

  @registration_id "00000000-0000-4000-8000-00000000000a"
  @peer_identity String.duplicate("a", 64)

  test "find returns the entry for one registration and nothing for another" do
    entries = [entry(@registration_id)]

    assert Enrollment.find(entries, @registration_id) == entry(@registration_id)
    assert Enrollment.find(entries, "00000000-0000-4000-8000-00000000000b") == nil
  end

  test "upsert appends a new registration and orders by registration id" do
    first = entry("00000000-0000-4000-8000-00000000000b")
    second = entry("00000000-0000-4000-8000-00000000000a")

    assert Enrollment.upsert([first], second) == [second, first]
  end

  test "upsert replaces the entry for the same registration without growing the list" do
    old = entry(@registration_id, max_biots: 4)
    new = entry(@registration_id, max_biots: 16)
    other = entry("00000000-0000-4000-8000-00000000000b")

    updated = Enrollment.upsert([old, other], new)

    assert length(updated) == 2
    assert Enrollment.find(updated, @registration_id) == new
  end

  test "validate accepts a canonical entry and rejects malformed fields" do
    assert Enrollment.validate(entry(@registration_id)) == :ok

    assert {:error, {:peer_identity, :invalid_format}} =
             Enrollment.validate(%{entry(@registration_id) | "peer_identity" => "short"})

    assert {:error, {:status, :invalid_value}} =
             Enrollment.validate(%{entry(@registration_id) | "status" => "on"})

    assert {:error, {:registration, :invalid_format}} = Enrollment.validate("not an entry")
  end

  defp entry(registration_id, options \\ []) do
    %{
      "node_id" => "00000000-0000-4000-8000-000000000001",
      "registration_id" => registration_id,
      "peer_identity" => @peer_identity,
      "max_biots" => Keyword.get(options, :max_biots, 4),
      "status" => "enabled"
    }
  end
end
