defmodule Biot.Server.Nodes.PlanTest do
  use ExUnit.Case, async: true

  alias Biot.Protocol.NodeId
  alias Biot.Protocol.RegistrationId
  alias Biot.Server.Nodes.Plan
  alias Biot.Server.Nodes.Registration
  alias Biot.Server.Schema.Node

  @statuses [:enabled, :disabled, :retired, :abandoned]

  test "new registrations are inserted with every requested status" do
    for status <- @statuses do
      registration = registration(1, status: status)
      assert_plan([], [registration], [{:insert, registration}], [])
    end
  end

  test "every ordered status pair has the expected result" do
    id = node_id(1)

    expectations = %{
      {:enabled, :enabled} => {:ok, [], []},
      {:enabled, :disabled} =>
        {:ok, [{:update_status, id, :disabled}, {:increment_access_revisions, id}], [id]},
      {:enabled, :retired} =>
        {:ok, [{:update_status, id, :retired}, {:increment_access_revisions, id}], [id]},
      {:enabled, :abandoned} =>
        {:ok,
         [
           {:update_status, id, :abandoned},
           {:increment_access_revisions, id},
           {:fail_operations, id}
         ], [id]},
      {:disabled, :enabled} => {:ok, [{:update_status, id, :enabled}], []},
      {:disabled, :disabled} => {:ok, [], []},
      {:disabled, :retired} => {:ok, [{:update_status, id, :retired}], [id]},
      {:disabled, :abandoned} =>
        {:ok,
         [
           {:update_status, id, :abandoned},
           {:increment_access_revisions, id},
           {:fail_operations, id}
         ], [id]},
      {:retired, :enabled} => {:error, {:terminal_node_locked, id, :retired}},
      {:retired, :disabled} => {:error, {:terminal_node_locked, id, :retired}},
      {:retired, :retired} => {:ok, [], []},
      {:retired, :abandoned} => {:error, {:terminal_node_locked, id, :retired}},
      {:abandoned, :enabled} => {:error, {:terminal_node_locked, id, :abandoned}},
      {:abandoned, :disabled} => {:error, {:terminal_node_locked, id, :abandoned}},
      {:abandoned, :retired} => {:error, {:terminal_node_locked, id, :abandoned}},
      {:abandoned, :abandoned} => {:ok, [], []}
    }

    assert MapSet.new(Map.keys(expectations)) ==
             MapSet.new(
               for current <- @statuses, requested <- @statuses, do: {current, requested}
             )

    for {{current, requested}, expected} <- expectations do
      result =
        Plan.plan(
          [existing_node(1, status: current)],
          [registration(1, status: requested)],
          MapSet.new()
        )

      assert_result(result, expected, "#{current} to #{requested}")
    end
  end

  test "omission disables only enabled nodes" do
    for status <- @statuses do
      node = existing_node(1, status: status)

      case status do
        :enabled ->
          assert_plan(
            [node],
            [],
            [{:update_status, node.id, :disabled}, {:increment_access_revisions, node.id}],
            [node.id]
          )

        _terminal_or_disabled ->
          assert_plan([node], [], [], [])
      end
    end
  end

  test "peer identity replacement keeps the binding and closes the connection" do
    node = existing_node(1)
    replacement = registration(1, peer_number: 2)

    assert_plan(
      [node],
      [replacement],
      [{:replace_peer_identity, node.id, replacement.peer_identity}],
      [node.id]
    )
  end

  test "registration IDs and identities owned by another node cannot be rebound" do
    cases = [
      {[existing_node(1)], registration(1, registration_number: 2)},
      {[existing_node(1)], registration(2, registration_number: 1)},
      {[existing_node(1)], registration(2, peer_number: 1)}
    ]

    for {existing, configured} <- cases do
      assert Plan.plan(existing, [configured], MapSet.new()) ==
               {:error, {:rebinding, configured.node_id}}
    end
  end

  test "terminal nodes reject peer identity and capacity changes" do
    for status <- [:retired, :abandoned], change <- [:peer_identity, :capacity] do
      configured =
        case change do
          :peer_identity -> registration(1, status: status, peer_number: 2)
          :capacity -> registration(1, status: status, max_biots: 11)
        end

      assert Plan.plan([existing_node(1, status: status)], [configured], MapSet.new()) ==
               {:error, {:terminal_node_locked, node_id(1), status}}
    end
  end

  test "retirement is blocked only when the node may have allocations" do
    node = existing_node(1)
    requested = registration(1, status: :retired)

    assert Plan.plan([node], [requested], MapSet.new([node.id])) ==
             {:error, {:retirement_blocked, node.id}}

    assert_plan(
      [node],
      [requested],
      [{:update_status, node.id, :retired}, {:increment_access_revisions, node.id}],
      [node.id]
    )
  end

  test "duplicate configuration identities are rejected" do
    cases = [
      {registration(1), registration(1, registration_number: 2, peer_number: 2), :duplicate_node},
      {registration(1), registration(2, registration_number: 1), :duplicate_registration},
      {registration(1), registration(2, peer_number: 1), :duplicate_peer_identity}
    ]

    for {first, second, rule} <- cases do
      assert Plan.plan([], [first, second], MapSet.new()) ==
               {:error, {rule, first.node_id}}
    end
  end

  test "capacity changes do not close a connection" do
    assert_plan(
      [existing_node(1)],
      [registration(1, max_biots: 11)],
      [{:update_max_biots, node_id(1), 11}],
      []
    )
  end

  test "message returns text for every plan rejection" do
    rejections = [
      {:duplicate_node, node_id(1)},
      {:duplicate_registration, node_id(1)},
      {:duplicate_peer_identity, node_id(1)},
      {:rebinding, node_id(1)},
      {:terminal_node_locked, node_id(1), :retired},
      {:terminal_node_locked, node_id(1), :abandoned},
      {:retirement_blocked, node_id(1)}
    ]

    for rejection <- rejections do
      message = Plan.message(rejection)
      assert message != ""
      assert message =~ to_string(node_id(1))
    end
  end

  defp assert_plan(existing, registrations, writes, close_connections) do
    result = Plan.plan(existing, registrations, MapSet.new())
    assert_result(result, {:ok, writes, close_connections}, "plan")
  end

  defp assert_result({:ok, %Plan{} = plan}, {:ok, writes, close_connections}, label) do
    assert MapSet.new(plan.writes) == MapSet.new(writes), "writes for #{label}"

    assert MapSet.new(plan.close_connections) == MapSet.new(close_connections),
           "closures for #{label}"
  end

  defp assert_result(result, expected, label), do: assert(result == expected, label)

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
