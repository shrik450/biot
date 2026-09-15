defmodule Biot.Protocol.LimitsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Biot.Protocol.BiotSpec
  alias Biot.Protocol.Desired
  alias Biot.Protocol.EnvironmentSelection
  alias Biot.Protocol.ExecutionSpec
  alias Biot.Protocol.Frame
  alias Biot.Protocol.Limits
  alias Biot.Protocol.Message
  alias Biot.Protocol.RepositorySource
  alias Biot.Protocol.SourceSelector
  alias Biot.Protocol.TestGenerators, as: Generators
  alias Biot.Protocol.Wire

  test "repository URLs enforce the byte limit" do
    limit = Limits.max_repository_url_bytes()

    for size <- [limit - 1, limit] do
      assert {:ok, _repository} = RepositorySource.parse(repository_url(size))
    end

    assert RepositorySource.parse(repository_url(limit + 1)) ==
             {:error, :repository_url_too_long}
  end

  test "source refs enforce the byte limit" do
    limit = Limits.max_source_ref_bytes()
    url = "https://example.test/repository.git"

    for size <- [limit - 1, limit] do
      assert {:ok, _selector} = SourceSelector.parse(url <> "#" <> String.duplicate("r", size))
    end

    assert SourceSelector.parse(url <> "#" <> String.duplicate("r", limit + 1)) ==
             {:error, :source_ref_too_long}
  end

  test "environment selections enforce every component limit" do
    layer_limit = Limits.max_layers()

    for count <- [layer_limit - 1, layer_limit] do
      assert {:ok, _selection} =
               EnvironmentSelection.parse(selection(List.duplicate("nixpkgs", count)))
    end

    assert EnvironmentSelection.parse(selection(List.duplicate("nixpkgs", layer_limit + 1))) ==
             {:error, :too_many_layers}

    assert_selection_bound(:base_nixpkgs, :repository_url_too_long)
    assert_selection_bound(:source_ref, :source_ref_too_long)
  end

  property "bounded parsers handle random binary input without raising" do
    check all(value <- StreamData.binary()) do
      assert_parser_result(RepositorySource.parse(value))
      assert_parser_result(SourceSelector.parse(value))
      assert EnvironmentSelection.parse(value) == {:error, :invalid_format}
    end
  end

  test "a spec at every component limit fits the wire and minimum frame" do
    spec = maximal_parsed_spec()
    encoded_spec_bytes = spec |> BiotSpec.encode() |> Jason.encode!() |> byte_size()

    assert encoded_spec_bytes <= Limits.max_biot_spec_bytes(1)

    encoded_messages =
      for message <- [
            %Message.Desired{biot_spec: spec},
            %Message.SynchronizeItem{biot_spec: spec}
          ] do
        assert {:ok, encoded} = Wire.encode(message, 1)
        encoded
      end

    for encoded <- encoded_messages do
      assert byte_size(encoded) + Frame.overhead_bytes() <= Wire.min_frame_bytes(1)
    end

    envelope_bytes =
      encoded_messages
      |> Enum.map(&(byte_size(&1) - encoded_spec_bytes))
      |> Enum.max()

    assert Wire.min_frame_bytes(1) >=
             Limits.max_biot_spec_bytes(1) + envelope_bytes + Frame.overhead_bytes()
  end

  test "Wire rejects a hand-built spec over the version bound" do
    encoded =
      Generators.biot_spec()
      |> pick()
      |> BiotSpec.encode()
      |> put_in(
        ["execution", "repository"],
        repository_url(Limits.max_biot_spec_bytes(1) + 1)
      )
      |> then(&%{"type" => Message.SynchronizeItem.type(), "biot_spec" => &1})
      |> Jason.encode!()

    assert Wire.decode(encoded, 1) == {:error, :biot_spec_too_large}
  end

  test "Wire rejects an oversized spec before encoding a spec-carrying message" do
    spec = pick(Generators.biot_spec())

    oversized = %{
      spec
      | execution: %{
          spec.execution
          | repository: %RepositorySource{
              url: repository_url(Limits.max_biot_spec_bytes(1) + 1)
            }
        }
    }

    for message <- [
          %Message.Desired{biot_spec: oversized},
          %Message.SynchronizeItem{biot_spec: oversized}
        ] do
      assert Wire.encode(message, 1) == {:error, :biot_spec_too_large}
    end
  end

  test "the startup check accepts the minimum and raises one byte below it" do
    minimum = Wire.min_frame_bytes(1)

    assert Wire.check_frame_limit!(minimum) == :ok

    assert_raise RuntimeError,
                 "max_frame_bytes must be at least #{minimum} bytes for protocol version 1; got #{minimum - 1}",
                 fn -> Wire.check_frame_limit!(minimum - 1) end
  end

  defp assert_selection_bound(:base_nixpkgs, reason) do
    limit = Limits.max_repository_url_bytes()

    for size <- [limit - 1, limit] do
      assert {:ok, _selection} =
               EnvironmentSelection.parse(selection([], repository_url(size) <> "#main"))
    end

    assert EnvironmentSelection.parse(selection([], repository_url(limit + 1) <> "#main")) ==
             {:error, reason}
  end

  defp assert_selection_bound(:source_ref, reason) do
    limit = Limits.max_source_ref_bytes()
    prefix = "https://example.test/repository.git#"

    for size <- [limit - 1, limit] do
      assert {:ok, _selection} =
               EnvironmentSelection.parse(selection([], prefix <> String.duplicate("r", size)))
    end

    assert EnvironmentSelection.parse(selection([], prefix <> String.duplicate("r", limit + 1))) ==
             {:error, reason}
  end

  defp maximal_parsed_spec do
    {:ok, repository} = RepositorySource.parse(repository_url(Limits.max_repository_url_bytes()))

    selector_text =
      repository_url(Limits.max_repository_url_bytes()) <>
        "#" <> String.duplicate("r", Limits.max_source_ref_bytes())

    {:ok, selector} = SourceSelector.parse(selector_text)

    environment_id = pick(Generators.environment_id())

    %BiotSpec{
      execution: %ExecutionSpec{
        biot_id: pick(Generators.biot_id()),
        repository: repository,
        desired: %Desired{revision: 1, state: :running, environment_id: environment_id},
        environment: %{
          id: environment_id,
          selection: %EnvironmentSelection{
            base_nixpkgs: selector,
            layers: List.duplicate(selector, Limits.max_layers())
          }
        }
      },
      access_revision: 1
    }
  end

  defp selection(layers, base \\ "nixpkgs") do
    %{"base_nixpkgs" => base, "layers" => layers}
  end

  defp repository_url(size) do
    prefix = "https://example.test/"
    prefix <> String.duplicate("r", size - byte_size(prefix))
  end

  defp assert_parser_result({:ok, _value}), do: :ok
  defp assert_parser_result({:error, reason}) when is_atom(reason), do: :ok
end
