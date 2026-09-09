defmodule Biot.Protocol.CompositeValueTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Biot.Protocol.ContainerState
  alias Biot.Protocol.EnvironmentSelection
  alias Biot.Protocol.Failure
  alias Biot.Protocol.Manifest
  alias Biot.Protocol.ParsedList
  alias Biot.Protocol.TestGenerators, as: Generators

  property "Failure round-trips through its encoded map" do
    check all(value <- Generators.failure()) do
      assert Failure.parse(Failure.encode(value)) == {:ok, value}
    end
  end

  property "Manifest round-trips through its encoded map" do
    check all(value <- Generators.manifest()) do
      assert Manifest.parse(Manifest.encode(value)) == {:ok, value}
    end
  end

  property "EnvironmentSelection round-trips through its encoded map" do
    check all(value <- Generators.environment_selection()) do
      assert EnvironmentSelection.parse(EnvironmentSelection.encode(value)) == {:ok, value}
    end
  end

  property "ContainerState round-trips through its encoded map" do
    check all(value <- Generators.container_state()) do
      assert ContainerState.parse(ContainerState.encode(value)) == {:ok, value}
    end
  end

  property "composite parsers never raise for arbitrary maps" do
    check all(value <- StreamData.map_of(StreamData.term(), StreamData.term(), max_length: 8)) do
      for module <- composite_modules() do
        assert_parse_result(module.parse(value))
      end
    end
  end

  property "composite parsers never raise for arbitrary terms" do
    check all(value <- StreamData.term()) do
      for module <- composite_modules() do
        assert_parse_result(module.parse(value))
      end
    end
  end

  property "composite parsers never raise when an encoded key is removed" do
    check all(
            {module, encoded} <- encoded_value(),
            key <- StreamData.member_of(Map.keys(encoded))
          ) do
      encoded
      |> Map.delete(key)
      |> module.parse()
      |> assert_parse_result()
    end
  end

  property "composite parsers never raise when an encoded value is replaced" do
    check all(
            {module, encoded} <- encoded_value(),
            key <- StreamData.member_of(Map.keys(encoded)),
            replacement <- StreamData.term()
          ) do
      encoded
      |> Map.put(key, replacement)
      |> module.parse()
      |> assert_parse_result()
    end
  end

  test "ParsedList returns an element error" do
    parser = fn
      value when is_integer(value) -> {:ok, value}
      _value -> {:error, :bad_element}
    end

    assert ParsedList.parse([1, :bad, 2], parser) == {:error, :bad_element}
  end

  defp composite_modules do
    [Failure, Manifest, EnvironmentSelection, ContainerState]
  end

  defp assert_parse_result({:ok, _value}), do: :ok
  defp assert_parse_result({:error, reason}) when is_atom(reason), do: :ok

  defp assert_parse_result(result) do
    flunk("parser returned #{inspect(result)}")
  end

  defp encoded_value do
    StreamData.one_of([
      StreamData.map(Generators.failure(), &{Failure, Failure.encode(&1)}),
      StreamData.map(Generators.manifest(), &{Manifest, Manifest.encode(&1)}),
      StreamData.map(
        Generators.environment_selection(),
        &{EnvironmentSelection, EnvironmentSelection.encode(&1)}
      ),
      StreamData.map(Generators.container_state(), &{ContainerState, ContainerState.encode(&1)})
    ])
  end
end
