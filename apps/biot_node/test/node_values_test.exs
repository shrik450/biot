defmodule Biot.Node.NodeValuesTest do
  @moduledoc false
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Biot.Node.ArtifactId
  alias Biot.Node.NetworkId
  alias Biot.Node.NodePrivatePath

  @modules [NodePrivatePath, ArtifactId, NetworkId]

  describe "NodePrivatePath" do
    test "accepts an absolute path in its canonical spelling" do
      for value <- [
            "/a",
            "/var/lib/biot",
            "/var/lib/biot/allocations/00000000-0000-4000-8000-0000000000b1",
            "/var/lib/biot/résolutions/e1",
            "/ "
          ] do
        assert {:ok, path} = NodePrivatePath.parse(value)
        assert NodePrivatePath.to_string(path) == value
        assert to_string(path) == value
      end
    end

    test "rejects anything that is not the canonical spelling of an absolute path" do
      for value <- [
            "",
            "/",
            "a",
            "relative/path",
            "./relative",
            "../escape",
            "/a/",
            "//a",
            "/a//b",
            "/a/./b",
            "/a/../b",
            "/.",
            "/..",
            "/a/b/..",
            <<"/a", 0, "b">>
          ] do
        assert NodePrivatePath.parse(value) == {:error, :invalid_format},
               "accepted #{inspect(value)}"
      end
    end

    test "rejects terms that are not binaries" do
      for value <- [nil, 1, :atom, %{}, [], {}, ["/a"], 1.5] do
        assert NodePrivatePath.parse(value) == {:error, :invalid_format},
               "accepted #{inspect(value)}"
      end
    end
  end

  describe "ArtifactId" do
    test "accepts any non-empty printable token the environment implementation mints" do
      for value <- [
            "/nix/store/9xr1-biot-env-e1",
            "-leading-dash",
            ".leading-dot",
            "two words",
            "x",
            "résultat"
          ] do
        assert {:ok, artifact} = ArtifactId.parse(value)
        assert ArtifactId.to_string(artifact) == value
        assert to_string(artifact) == value
      end
    end

    test "rejects an empty or unprintable token" do
      for value <- ["", <<0>>, <<255>>, <<0xFF, 0xFE>>, "a" <> <<0>>, nil, 1, :atom, %{}, []] do
        assert ArtifactId.parse(value) == {:error, :invalid_format}, "accepted #{inspect(value)}"
      end
    end
  end

  describe "NetworkId" do
    test "accept a canonical random UUID" do
      for value <- ["00000000-0000-4000-8000-0000000000a1", uuid()] do
        assert {:ok, id} = NetworkId.parse(value)
        assert NetworkId.to_string(id) == value
        assert to_string(id) == value
      end
    end

    test "reject anything that is not a canonical random UUID" do
      for value <- [
            "",
            "00000000-0000-4000-8000-0000000000A1",
            "00000000-0000-1000-8000-0000000000a1",
            "00000000-0000-4000-c000-0000000000a1",
            "00000000-0000-4000-8000-0000000000a",
            "00000000-0000-4000-8000-0000000000a1x",
            "000000000000400080000000000000a1",
            "not-a-uuid",
            nil,
            1,
            :atom,
            %{}
          ] do
        assert NetworkId.parse(value) == {:error, :invalid_format},
               "NetworkId accepted #{inspect(value)}"
      end
    end
  end

  describe "fuzzing the node's own parsers" do
    property "parse/1 answers ok or an error atom for any binary" do
      check all(value <- StreamData.binary()) do
        for module <- @modules, do: assert_parse_result(module, module.parse(value))
      end
    end

    property "parse/1 answers ok or an error atom for any term" do
      check all(value <- StreamData.term()) do
        for module <- @modules, do: assert_parse_result(module, module.parse(value))
      end
    end

    property "parse/1 answers ok or an error atom for any path-like binary" do
      check all(
              leading <- StreamData.member_of(["", "/", "//", "./", "../"]),
              segments <-
                StreamData.list_of(
                  StreamData.member_of(["a", "", ".", "..", " ", "b/c", "é"]),
                  max_length: 4
                ),
              trailing <- StreamData.member_of(["", "/"])
            ) do
        value = leading <> Enum.join(segments, "/") <> trailing

        assert_parse_result(NodePrivatePath, NodePrivatePath.parse(value))
      end
    end

    property "a parsed value always spells itself back the same way" do
      check all(value <- StreamData.binary(min_length: 1)) do
        for module <- @modules, do: assert_round_trip(module, module.parse(value), value)
      end
    end
  end

  defp assert_parse_result(_module, {:ok, _parsed}), do: assert(true)
  defp assert_parse_result(_module, {:error, reason}), do: assert(is_atom(reason))

  defp assert_round_trip(module, {:ok, parsed}, value) do
    assert module.to_string(parsed) == value
  end

  defp assert_round_trip(_module, {:error, _reason}, _value), do: assert(true)

  defp uuid do
    hex = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    variant = Enum.random(~w(8 9 a b))

    Enum.join(
      [
        String.slice(hex, 0, 8),
        String.slice(hex, 8, 4),
        "4" <> String.slice(hex, 13, 3),
        variant <> String.slice(hex, 17, 3),
        String.slice(hex, 20, 12)
      ],
      "-"
    )
  end
end
