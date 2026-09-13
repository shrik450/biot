defmodule Biot.Node.Streams.GroupsTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Biot.Node.Streams.Groups
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.ConnectionId

  @biot_a "11111111-2222-4333-8444-555555555555"
  @biot_b "22222222-3333-4444-8555-666666666666"
  @connection_one "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
  @connection_two "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"

  defp biot_a, do: elem(BiotId.parse(@biot_a), 1)
  defp biot_b, do: elem(BiotId.parse(@biot_b), 1)
  defp connection_one, do: elem(ConnectionId.parse(@connection_one), 1)
  defp connection_two, do: elem(ConnectionId.parse(@connection_two), 1)

  describe "apply_revision/4" do
    test "a biot with no group gets an empty group for the connection and revision" do
      assert {:applied, state, []} =
               Groups.apply_revision(Groups.new(), biot_a(), connection_one(), 5)

      assert group(state, biot_a()) == %{
               connection_id: connection_one(),
               revision: 5,
               children: MapSet.new()
             }
    end

    test "repeating the applied revision acknowledges again without touching the group" do
      state = applied(biot_a(), connection_one(), 5)
      state = put_child(state, biot_a(), self())

      assert {:applied, ^state, []} = Groups.apply_revision(state, biot_a(), connection_one(), 5)
    end

    test "a lower revision is ignored and never shrinks the applied revision" do
      state = applied(biot_a(), connection_one(), 5)
      state = put_child(state, biot_a(), self())

      assert {:ignored, ^state} = Groups.apply_revision(state, biot_a(), connection_one(), 4)
      assert group(state, biot_a()).revision == 5
    end

    test "a higher revision replaces the group and reports its children for termination" do
      state = applied(biot_a(), connection_one(), 5)
      child = start_child()
      state = put_child(state, biot_a(), child)

      assert {:applied, next, [{:terminate, pids}]} =
               Groups.apply_revision(state, biot_a(), connection_one(), 6)

      assert pids == [child]

      assert group(next, biot_a()) == %{
               connection_id: connection_one(),
               revision: 6,
               children: MapSet.new()
             }
    end

    test "the same revision on a different connection is a new group and closes the old children" do
      state = applied(biot_a(), connection_one(), 5)
      child = start_child()
      state = put_child(state, biot_a(), child)

      assert {:applied, next, [{:terminate, [^child]}]} =
               Groups.apply_revision(state, biot_a(), connection_two(), 5)

      assert group(next, biot_a()).connection_id == connection_two()
    end

    test "a lower revision on a different connection is still ignored" do
      state = applied(biot_a(), connection_one(), 5)

      assert {:ignored, ^state} = Groups.apply_revision(state, biot_a(), connection_two(), 4)
    end

    test "one biot's revision change leaves every other biot's group alone" do
      state = applied(biot_a(), connection_one(), 5)
      state = put_child(state, biot_a(), self())
      state = applied(state, biot_b(), connection_one(), 9)
      state = put_child(state, biot_b(), self())

      assert {:applied, next, [{:terminate, [child]}]} =
               Groups.apply_revision(state, biot_a(), connection_one(), 6)

      assert child in MapSet.to_list(group(state, biot_a()).children)
      assert group(next, biot_b()) == group(state, biot_b())
    end
  end

  describe "admit/5" do
    test "refuses a biot with no group" do
      assert Groups.admit(Groups.new(), limits(), biot_a(), connection_one(), 1) ==
               {:refuse, :unknown_biot}
    end

    test "admits only the current connection and revision" do
      state = applied(biot_a(), connection_one(), 5)

      assert Groups.admit(state, limits(), biot_a(), connection_one(), 5) == :ok

      assert Groups.admit(state, limits(), biot_a(), connection_one(), 4) ==
               {:refuse, :stale_access}

      assert Groups.admit(state, limits(), biot_a(), connection_one(), 6) ==
               {:refuse, :stale_access}

      assert Groups.admit(state, limits(), biot_a(), connection_two(), 5) ==
               {:refuse, :stale_access}

      assert Groups.admit(state, limits(), biot_b(), connection_one(), 5) ==
               {:refuse, :unknown_biot}
    end

    test "refuses when the biot already holds the per-biot limit" do
      state = applied(biot_a(), connection_one(), 5)
      state = put_children(state, biot_a(), 2)

      assert Groups.admit(state, %{total: 100, per_biot: 2}, biot_a(), connection_one(), 5) ==
               {:refuse, :too_many_streams}

      assert Groups.admit(state, %{total: 100, per_biot: 3}, biot_a(), connection_one(), 5) == :ok
    end

    test "refuses when the node already holds the total limit across every biot" do
      state = applied(biot_a(), connection_one(), 5)
      state = applied(state, biot_b(), connection_one(), 5)
      state = put_children(state, biot_a(), 2)
      state = put_children(state, biot_b(), 2)

      assert Groups.admit(state, %{total: 4, per_biot: 10}, biot_a(), connection_one(), 5) ==
               {:refuse, :too_many_streams}

      assert Groups.admit(state, %{total: 5, per_biot: 10}, biot_a(), connection_one(), 5) == :ok
    end
  end

  describe "children and close_all/1" do
    test "put_child records a child once and child_down removes exactly it" do
      state = applied(biot_a(), connection_one(), 5)
      first = start_child()
      second = start_child()

      state = put_child(state, biot_a(), first)
      state = put_child(state, biot_a(), second)
      state = put_child(state, biot_a(), first)

      assert MapSet.new([first, second]) == group(state, biot_a()).children

      state = Groups.child_down(state, first)
      assert MapSet.new([second]) == group(state, biot_a()).children
    end

    test "close_all reports every child once and empties every group" do
      state = applied(biot_a(), connection_one(), 5)
      state = applied(state, biot_b(), connection_one(), 5)
      first = start_child()
      second = start_child()
      state = put_child(state, biot_a(), first)
      state = put_child(state, biot_b(), second)

      assert {closed, [{:terminate, pids}]} = Groups.close_all(state)
      assert Enum.sort(pids) == Enum.sort([first, second])
      assert closed.groups == %{}

      assert Groups.admit(closed, limits(), biot_a(), connection_one(), 5) ==
               {:refuse, :unknown_biot}
    end

    test "close_all on an empty core reports no effect" do
      assert {state, []} = Groups.close_all(Groups.new())
      assert state.groups == %{}
    end

    test "a group with no children reports no termination effect" do
      state = applied(biot_a(), connection_one(), 5)

      assert {:applied, next, []} = Groups.apply_revision(state, biot_a(), connection_one(), 6)
      assert next.groups != %{}
    end
  end

  defp applied(biot_id, connection_id, revision),
    do: applied(Groups.new(), biot_id, connection_id, revision)

  defp applied(state, biot_id, connection_id, revision) do
    {:applied, next, []} = Groups.apply_revision(state, biot_id, connection_id, revision)
    next
  end

  defp group(state, biot_id), do: Map.fetch!(state.groups, biot_id)

  defp put_child(state, biot_id, pid), do: Groups.put_child(state, biot_id, pid)

  defp put_children(state, biot_id, count) do
    Enum.reduce(1..count, state, fn _index, acc ->
      Groups.put_child(acc, biot_id, start_child())
    end)
  end

  defp limits, do: %{total: 100, per_biot: 100}

  defp start_child do
    spawn_link(fn -> settle() end)
  end

  defp settle do
    receive do
      :stop -> :ok
    end
  end
end
