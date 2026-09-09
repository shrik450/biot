defmodule Biot.Node.Control.StagingTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Biot.Node.Control.Staging
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.BiotSpec
  alias Biot.Protocol.ConnectionId

  import Biot.Node.ReconcileFixtures

  test "begin accepts counts through capacity and rejects the next count" do
    connection_id = connection_id(1)

    for count <- [0, 1, 3] do
      assert {:ok, %Staging{connection_id: ^connection_id, expected_count: ^count, specs: %{}}} =
               Staging.begin(connection_id, count, 3)
    end

    assert Staging.begin(connection_id, 4, 3) == {:error, :snapshot_count_over_capacity}
  end

  test "add covers success, duplicate IDs, and the declared count" do
    first = biot_spec(fixture_biot_id(), 1)
    duplicate = biot_spec(fixture_biot_id(), 2)
    second = biot_spec(other_biot_id(), 1)

    assert {:ok, staging} = Staging.begin(connection_id(1), 1, 10)
    assert {:ok, staging} = Staging.add(staging, first)
    assert Staging.add(staging, duplicate) == {:error, :duplicate_biot_id}
    assert Staging.add(staging, second) == {:error, :staged_count_exceeded}
  end

  test "complete covers success, short count, and a different connection" do
    current = connection_id(1)
    stale = connection_id(2)
    spec = biot_spec(biot_id(), 1)

    assert {:ok, empty} = Staging.begin(current, 1, 10)
    assert Staging.complete(empty, current) == {:error, :synchronize_count_mismatch}
    assert Staging.complete(empty, stale) == {:error, :synchronize_connection_mismatch}

    assert {:ok, full} = Staging.add(empty, spec)
    assert {:ok, [^spec]} = Staging.complete(full, current)
    assert Staging.complete(full, stale) == {:error, :synchronize_connection_mismatch}
  end

  property "the begin, add, and complete table agrees with its count model" do
    check all(expected <- StreamData.integer(0..8), received <- StreamData.integer(0..10)) do
      connection_id = connection_id(1)

      case Staging.begin(connection_id, expected, 8) do
        {:error, reason} ->
          assert expected > 8
          assert reason == :snapshot_count_over_capacity

        {:ok, staging} ->
          {staging, error} = add_distinct(staging, received)

          if received > expected do
            assert error == :staged_count_exceeded
          else
            assert error == nil

            expected_result = if received == expected, do: :ok, else: :synchronize_count_mismatch

            case Staging.complete(staging, connection_id) do
              {:ok, specs} ->
                assert expected_result == :ok
                assert length(specs) == expected

              {:error, reason} ->
                assert reason == expected_result
            end
          end
      end
    end
  end

  defp add_distinct(staging, count) do
    Enum.reduce_while(1..count//1, {staging, nil}, fn number, {current, nil} ->
      case Staging.add(current, biot_spec(fixture_biot_id(number), 1)) do
        {:ok, next} -> {:cont, {next, nil}}
        {:error, reason} -> {:halt, {current, reason}}
      end
    end)
  end

  defp biot_spec(id, access_revision) do
    %BiotSpec{execution: spec(biot_id: id), access_revision: access_revision}
  end

  defp fixture_biot_id(number \\ 1) do
    {:ok, id} =
      BiotId.parse(
        "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(number), 12, "0")
      )

    id
  end

  defp connection_id(number) do
    {:ok, id} =
      ConnectionId.parse(
        "10000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(number), 12, "0")
      )

    id
  end
end
