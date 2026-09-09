defmodule Biot.Server.Nodes.RegistrationTest do
  use ExUnit.Case, async: true

  alias Biot.Server.Nodes.Registration

  @node_id "00000000-0000-4000-8000-000000000001"
  @registration_id "00000000-0000-4000-8000-000000000002"
  @peer_identity String.duplicate("a", 64)

  test "parse accepts the loader's string-keyed JSON shape" do
    value = %{
      "node_id" => @node_id,
      "registration_id" => @registration_id,
      "peer_identity" => @peer_identity,
      "max_biots" => 4,
      "status" => "enabled"
    }

    assert {:ok, registration} = Registration.parse(value)
    assert registration.max_biots == 4
    assert registration.status == :enabled
    assert to_string(registration.node_id) == @node_id
    assert to_string(registration.registration_id) == @registration_id
    assert registration.peer_identity == @peer_identity
  end

  test "parse accepts atom keys and parsed status atoms" do
    value = %{
      node_id: @node_id,
      registration_id: @registration_id,
      peer_identity: @peer_identity,
      max_biots: 1,
      status: :retired
    }

    assert {:ok, registration} = Registration.parse(value)
    assert registration.status == :retired
  end

  test "parse rejects invalid fields" do
    valid = %{
      "node_id" => @node_id,
      "registration_id" => @registration_id,
      "peer_identity" => @peer_identity,
      "max_biots" => 4,
      "status" => "enabled"
    }

    cases = [
      {:bad_status, Map.put(valid, "status", "paused"), {:status, :invalid_value}},
      {:zero_capacity, Map.put(valid, "max_biots", 0), {:max_biots, :not_positive}},
      {:negative_capacity, Map.put(valid, "max_biots", -1), {:max_biots, :not_positive}},
      {:bad_node_id, Map.put(valid, "node_id", "not-an-id"), {:node_id, :invalid_format}},
      {:bad_registration_id, Map.put(valid, "registration_id", "not-an-id"),
       {:registration_id, :invalid_format}},
      {:bad_peer_identity, Map.put(valid, "peer_identity", "ABC"),
       {:peer_identity, :invalid_format}}
    ]

    for {label, value, reason} <- cases do
      assert Registration.parse(value) == {:error, reason}, "case #{label}"
    end
  end
end
