defmodule BiotWeb.BoundaryRobustnessTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Biot.Protocol.BiotId
  alias Biot.Server.Login.Callback
  alias BiotWeb.Api.BearerHeader
  alias BiotWeb.ClientAddress
  alias BiotWeb.Params

  property "bearer and callback boundaries handle arbitrary binary input" do
    check all(value <- StreamData.binary(), max_runs: 100) do
      assert_result(BearerHeader.token([value]), [:error, :ok])

      callback = Callback.parse(%{"state" => value, "code" => value}, value)
      assert_result(callback, [:error, :ok])
    end
  end

  property "parameter wrappers handle arbitrary values without raising" do
    check all(value <- StreamData.term(), max_runs: 100) do
      assert_result(Params.biot_id(%{"id" => value}), [:ok, :invalid_input])

      assert_result(
        Params.lifecycle_change(%{"id" => value}, %{"expected_revision" => value}),
        [:ok, :invalid_input]
      )
    end
  end

  property "client address boundaries handle arbitrary header and config bytes" do
    check all(value <- StreamData.binary(), max_runs: 100) do
      assert_result(ClientAddress.parse_peers(value), [:ok, :invalid_peer])

      assert ClientAddress.resolve({127, 0, 0, 1}, [], [value]) == {127, 0, 0, 1}
    end
  end

  test "client address parsing keeps the trusted edge boundary" do
    assert ClientAddress.parse_peers("127.0.0.1, ::1") ==
             {:ok, [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}]}

    assert ClientAddress.resolve(
             {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001},
             [{127, 0, 0, 1}],
             ["198.51.100.10, 203.0.113.20"]
           ) == {203, 0, 113, 20}

    assert ClientAddress.resolve(
             {127, 0, 0, 2},
             [{127, 0, 0, 1}],
             ["203.0.113.20"]
           ) == {127, 0, 0, 2}
  end

  test "parameter wrappers keep path identity separate and collect malformed fields" do
    id = BiotId.to_string(__MODULE__.TestFixtures.id(BiotId, 77))

    assert {:error, {:invalid_input, %{id: [:invalid_format], expected_revision: [:missing]}}} =
             Params.lifecycle_change(%{"id" => "not-an-id"}, %{})

    assert {:ok, {parsed_id, 7}} =
             Params.lifecycle_change(%{"id" => id}, %{"expected_revision" => 7})

    assert parsed_id == __MODULE__.TestFixtures.id(BiotId, 77)

    assert {:error, {:invalid_input, %{expected_revision: [:invalid_format]}}} =
             Params.lifecycle_change(%{"id" => id}, %{"expected_revision" => 0})
  end

  test "page parameters apply the documented default and bounds" do
    assert Params.page(%{}) == {:ok, %{after: nil, limit: 50}}
    assert {:ok, %{after: nil, limit: 200}} = Params.page(%{"limit" => "200"})

    assert {:error, {:invalid_input, %{limit: [:out_of_range]}}} =
             Params.page(%{"limit" => "0"})

    assert {:error, {:invalid_input, %{limit: [:out_of_range]}}} =
             Params.page(%{"limit" => "201"})

    assert {:error, {:invalid_input, %{limit: [:invalid_format]}}} =
             Params.page(%{"limit" => "20items"})
  end

  defp assert_result({:ok, _value}, allowed), do: assert(:ok in allowed)

  defp assert_result({:error, {:invalid_input, _fields}}, allowed),
    do: assert(:invalid_input in allowed)

  defp assert_result({:error, {:invalid_peer, _entry}}, allowed),
    do: assert(:invalid_peer in allowed)

  defp assert_result(:error, allowed), do: assert(:error in allowed)

  defp assert_result(result, _allowed),
    do: flunk("unexpected boundary result: #{inspect(result)}")

  defmodule TestFixtures do
    alias Biot.Protocol.BiotId

    @spec id(module(), pos_integer()) :: BiotId.t()
    def id(BiotId, number) do
      {:ok, id} =
        BiotId.parse(
          "00000000-0000-4000-8000-#{String.pad_leading(Integer.to_string(number), 12, "0")}"
        )

      id
    end
  end
end
