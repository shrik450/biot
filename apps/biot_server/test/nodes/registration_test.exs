defmodule Biot.Server.Nodes.RegistrationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

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

  test "parse accepts every node status in JSON and parsed forms" do
    for status <- [:enabled, :disabled, :retired, :abandoned],
        value <- [status, Atom.to_string(status)] do
      assert {:ok, registration} = Registration.parse(%{valid_registration() | "status" => value})
      assert registration.status == status
    end
  end

  test "parse rejects invalid fields" do
    valid = valid_registration()

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

  property "parse never raises for random terms" do
    terms = random_term()

    check all(value <- terms) do
      assert_parse_result(Registration.parse(value))
    end
  end

  property "parse never raises when a valid encoding loses or changes one field" do
    fields = Map.keys(valid_registration())
    terms = random_term()

    check all(
            field <- StreamData.member_of(fields),
            replacement <- terms,
            remove? <- StreamData.boolean()
          ) do
      changed =
        if remove?,
          do: Map.delete(valid_registration(), field),
          else: Map.put(valid_registration(), field, replacement)

      assert_parse_result(Registration.parse(changed))
    end
  end

  defp valid_registration do
    %{
      "node_id" => @node_id,
      "registration_id" => @registration_id,
      "peer_identity" => @peer_identity,
      "max_biots" => 4,
      "status" => "enabled"
    }
  end

  defp assert_parse_result({:ok, %Registration{}}), do: :ok
  defp assert_parse_result({:error, {_field, _reason}}), do: :ok
  defp assert_parse_result(result), do: flunk("parse returned #{inspect(result)}")

  defp random_term do
    StreamData.one_of([
      StreamData.binary(),
      StreamData.integer(),
      StreamData.float(),
      StreamData.list_of(StreamData.integer()),
      StreamData.map_of(StreamData.integer(), StreamData.binary()),
      StreamData.tuple({StreamData.integer(), StreamData.binary()}),
      StreamData.member_of([nil, true, false, :value, [], {}, %{}])
    ])
  end
end
