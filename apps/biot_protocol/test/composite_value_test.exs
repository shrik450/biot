defmodule Biot.Protocol.CompositeValueTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Biot.Protocol.ContainerState
  alias Biot.Protocol.EnvironmentSelection
  alias Biot.Protocol.Failure
  alias Biot.Protocol.Manifest
  alias Biot.Protocol.ParsedList
  alias Biot.Protocol.PrivateDiagnosticId
  alias Biot.Protocol.ProjectSnapshot
  alias Biot.Protocol.TestGenerators, as: Generators

  @stages ~w(allocate initialize resolve prepare install start retire remove_data release_allocation inspect)a
  @codes ~w(resource_unavailable invalid_source resolution_failed preparation_failed installation_failed container_failed lost_data inspection_failed)a
  @retries ~w(automatic after_change operator)a

  property "Failure round-trips through its encoded map" do
    check all(value <- failure()) do
      assert Failure.parse(Failure.encode(value)) == {:ok, value}
    end
  end

  property "Manifest round-trips through its encoded map" do
    check all(value <- manifest()) do
      assert Manifest.parse(Manifest.encode(value)) == {:ok, value}
    end
  end

  property "EnvironmentSelection round-trips through its encoded map" do
    check all(value <- environment_selection()) do
      assert EnvironmentSelection.parse(EnvironmentSelection.encode(value)) == {:ok, value}
    end
  end

  property "ContainerState round-trips through its encoded map" do
    check all(value <- container_state()) do
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
      StreamData.map(failure(), &{Failure, Failure.encode(&1)}),
      StreamData.map(manifest(), &{Manifest, Manifest.encode(&1)}),
      StreamData.map(
        environment_selection(),
        &{EnvironmentSelection, EnvironmentSelection.encode(&1)}
      ),
      StreamData.map(container_state(), &{ContainerState, ContainerState.encode(&1)})
    ])
  end

  defp failure do
    gen all(
          stage <- StreamData.member_of(@stages),
          code <- StreamData.member_of(@codes),
          retry_policy <- StreamData.member_of(@retries),
          message <- StreamData.string(:printable, max_length: 100),
          diagnostic_ref <- diagnostic_ref()
        ) do
      %Failure{
        stage: stage,
        code: code,
        retry: retry_policy,
        message: message,
        diagnostic_ref: diagnostic_ref
      }
    end
  end

  defp diagnostic_ref do
    StreamData.one_of([
      StreamData.constant(nil),
      StreamData.map(Generators.canonical_uuid(), fn value ->
        {:ok, diagnostic_ref} = PrivateDiagnosticId.parse(value)
        diagnostic_ref
      end)
    ])
  end

  defp manifest do
    gen all(
          base_nixpkgs <- Generators.pinned_source(),
          layers <- StreamData.list_of(Generators.pinned_source(), max_length: 4),
          project_snapshot <- project_snapshot()
        ) do
      Manifest.build(base_nixpkgs, layers, project_snapshot)
    end
  end

  defp project_snapshot do
    StreamData.one_of([
      StreamData.constant(nil),
      gen all(
            snapshot_id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 32),
            digest <- Generators.digest()
          ) do
        %ProjectSnapshot{snapshot_id: snapshot_id, digest: digest}
      end
    ])
  end

  defp environment_selection do
    gen all(
          base_nixpkgs <- Generators.source_selector(),
          layers <- StreamData.list_of(Generators.source_selector(), max_length: 4),
          project_context <-
            StreamData.one_of([
              StreamData.constant(nil),
              Generators.relative_directory()
            ])
        ) do
      %EnvironmentSelection{
        base_nixpkgs: base_nixpkgs,
        layers: layers,
        project_context: project_context
      }
    end
  end

  defp container_state do
    StreamData.one_of([
      StreamData.constant(:running),
      StreamData.map(StreamData.non_negative_integer(), &{:exited, &1})
    ])
  end
end
