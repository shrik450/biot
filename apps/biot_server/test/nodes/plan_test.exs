defmodule Biot.Server.Nodes.PlanTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Biot.Protocol.NodeId
  alias Biot.Protocol.RegistrationId
  alias Biot.Server.Nodes.Plan
  alias Biot.Server.Nodes.Registration
  alias Biot.Server.Schema.Node

  test "new registrations are inserted with their requested status" do
    for status <- [:enabled, :disabled, :retired] do
      registration = registration(1, status: status)

      assert Plan.plan([], [registration], MapSet.new()) ==
               {:ok, [{:insert, registration}]}
    end
  end

  test "identical registrations have no actions" do
    node = existing_node(1)

    assert Plan.plan([node], [registration(1)], MapSet.new()) == {:ok, []}
  end

  test "status changes update status and enabled departures increment access revisions" do
    cases = [
      {:disabled_to_enabled, existing_node(1, status: :disabled), registration(1),
       [{:update_status, node_id(1), :enabled}]},
      {:enabled_to_disabled, existing_node(2), registration(2, status: :disabled),
       [
         {:update_status, node_id(2), :disabled},
         {:increment_access_revisions, node_id(2)}
       ]},
      {:enabled_to_retired, existing_node(3), registration(3, status: :retired),
       [
         {:update_status, node_id(3), :retired},
         {:increment_access_revisions, node_id(3)}
       ]}
    ]

    for {label, existing, configured, actions} <- cases do
      assert Plan.plan([existing], [configured], MapSet.new()) == {:ok, actions},
             "case #{label}"
    end
  end

  test "omission disables enabled nodes and leaves disabled and retired nodes unchanged" do
    existing = [
      existing_node(1),
      existing_node(2, status: :disabled),
      existing_node(3, status: :retired)
    ]

    assert Plan.plan(existing, [], MapSet.new()) ==
             {:ok,
              [
                {:disable_omitted, node_id(1)},
                {:increment_access_revisions, node_id(1)}
              ]}
  end

  test "retired nodes cannot return to a non-retired status" do
    cases = [
      {:enabled, {:retired_cannot_enable, node_id(1)}},
      {:disabled, {:retired_cannot_disable, node_id(1)}}
    ]

    for {status, rejection} <- cases do
      assert Plan.plan(
               [existing_node(1, status: :retired)],
               [registration(1, status: status)],
               MapSet.new()
             ) ==
               {:error, rejection}
    end
  end

  test "registration IDs and peer identities cannot be rebound" do
    cases = [
      {:same_node_registration, [existing_node(1)], registration(1, registration_number: 2)},
      {:same_node_peer, [existing_node(1)], registration(1, peer_number: 2)},
      {:registration_on_another_node, [existing_node(1)],
       registration(2, registration_number: 1)},
      {:peer_on_another_node, [existing_node(1)], registration(2, peer_number: 1)}
    ]

    for {label, existing, configured} <- cases do
      assert Plan.plan(existing, [configured], MapSet.new()) ==
               {:error, {:rebinding, configured.node_id}},
             "case #{label}"
    end
  end

  test "retirement is blocked only for nodes in the allocation set" do
    node = existing_node(1)
    registration = registration(1, status: :retired)

    assert Plan.plan([node], [registration], MapSet.new([node.id])) ==
             {:error, {:retirement_blocked, node.id}}

    assert Plan.plan([node], [registration], MapSet.new()) ==
             {:ok,
              [
                {:update_status, node.id, :retired},
                {:increment_access_revisions, node.id}
              ]}
  end

  test "duplicate configuration identities are rejected" do
    cases = [
      {:node_id, registration(1), registration(1, registration_number: 2, peer_number: 2),
       :duplicate_node},
      {:registration_id, registration(1), registration(2, registration_number: 1),
       :duplicate_registration},
      {:peer_identity, registration(1), registration(2, peer_number: 1), :duplicate_peer_identity}
    ]

    for {label, first, second, rule} <- cases do
      assert Plan.plan([], [first, second], MapSet.new()) ==
               {:error, {rule, first.node_id}},
             "case #{label}"
    end
  end

  test "a max_biots change updates the node" do
    assert Plan.plan([existing_node(1)], [registration(1, max_biots: 11)], MapSet.new()) ==
             {:ok, [{:update_max_biots, node_id(1), 11}]}
  end

  test "message returns text for every rejection" do
    rejections = [
      {:duplicate_node, node_id(1)},
      {:duplicate_registration, node_id(1)},
      {:duplicate_peer_identity, node_id(1)},
      {:rebinding, node_id(1)},
      {:retired_cannot_enable, node_id(1)},
      {:retired_cannot_disable, node_id(1)},
      {:retirement_blocked, node_id(1)}
    ]

    for rejection <- rejections do
      message = Plan.message(rejection)
      assert is_binary(message)
      assert message != ""
    end
  end

  property "planning generated node lists never raises and actions name input nodes" do
    check all(
            existing <- StreamData.list_of(node_generator(), max_length: 8),
            registrations <- StreamData.list_of(registration_generator(), max_length: 8),
            allocated <- StreamData.list_of(node_id_generator(), max_length: 8)
          ) do
      case Plan.plan(existing, registrations, MapSet.new(allocated)) do
        {:error, _rejection} ->
          :ok

        {:ok, actions} ->
          input_ids =
            MapSet.new(Enum.map(existing, & &1.id) ++ Enum.map(registrations, & &1.node_id))

          assert Enum.all?(actions, fn action ->
                   MapSet.member?(input_ids, action_node_id(action))
                 end)
      end
    end
  end

  defp action_node_id({:insert, registration}), do: registration.node_id
  defp action_node_id({_action, node_id}), do: node_id
  defp action_node_id({_action, node_id, _value}), do: node_id

  defp existing_node(number, opts \\ []) do
    %Node{
      id: node_id(number),
      registration: registration_id(Keyword.get(opts, :registration_number, number)),
      peer_identity: peer_identity(Keyword.get(opts, :peer_number, number)),
      status: Keyword.get(opts, :status, :enabled),
      max_biots: Keyword.get(opts, :max_biots, 10)
    }
  end

  defp registration(number, opts \\ []) do
    %Registration{
      node_id: node_id(number),
      registration_id: registration_id(Keyword.get(opts, :registration_number, number)),
      peer_identity: peer_identity(Keyword.get(opts, :peer_number, number)),
      status: Keyword.get(opts, :status, :enabled),
      max_biots: Keyword.get(opts, :max_biots, 10)
    }
  end

  defp node_generator do
    gen all(
          id <- node_id_generator(),
          registration_id <- registration_id_generator(),
          peer_identity <- peer_identity_generator(),
          status <- StreamData.member_of([:enabled, :disabled, :retired]),
          max_biots <- StreamData.positive_integer()
        ) do
      %Node{
        id: id,
        registration: registration_id,
        peer_identity: peer_identity,
        status: status,
        max_biots: max_biots
      }
    end
  end

  defp registration_generator do
    gen all(
          node_id <- node_id_generator(),
          registration_id <- registration_id_generator(),
          peer_identity <- peer_identity_generator(),
          status <- StreamData.member_of([:enabled, :disabled, :retired]),
          max_biots <- StreamData.positive_integer()
        ) do
      %Registration{
        node_id: node_id,
        registration_id: registration_id,
        peer_identity: peer_identity,
        status: status,
        max_biots: max_biots
      }
    end
  end

  defp node_id_generator do
    StreamData.map(canonical_uuid_generator(), fn value ->
      {:ok, id} = NodeId.parse(value)
      id
    end)
  end

  defp registration_id_generator do
    StreamData.map(canonical_uuid_generator(), fn value ->
      {:ok, id} = RegistrationId.parse(value)
      id
    end)
  end

  defp canonical_uuid_generator do
    gen all(suffix <- StreamData.integer(0..999_999_999_999)) do
      "00000000-0000-4000-8000-" <>
        (suffix |> Integer.to_string() |> String.pad_leading(12, "0"))
    end
  end

  defp peer_identity_generator do
    StreamData.map(StreamData.binary(length: 32), &Base.encode16(&1, case: :lower))
  end

  defp node_id(number) do
    {:ok, id} = NodeId.parse(uuid(number))
    id
  end

  defp registration_id(number) do
    {:ok, id} = RegistrationId.parse(uuid(number + 100))
    id
  end

  defp peer_identity(number) do
    number
    |> Integer.to_string(16)
    |> String.pad_leading(64, "0")
  end

  defp uuid(number) do
    "00000000-0000-4000-8000-" <>
      (number |> Integer.to_string() |> String.pad_leading(12, "0"))
  end
end
