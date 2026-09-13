defmodule Biot.Protocol.ShellFrameTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Biot.Protocol.ShellFrame

  @max ShellFrame.max_payload()

  describe "encode/1" do
    test "data at the payload bound is accepted and one byte over is refused" do
      assert {:ok, _} = ShellFrame.encode({:data, :binary.copy(<<0>>, @max)})

      assert ShellFrame.encode({:data, :binary.copy(<<0>>, @max + 1)}) ==
               {:error, :frame_too_large}
    end

    test "resize takes both dimensions in 1..65535" do
      assert {:ok, [<<1, 0, 0, 0, 4>>, <<1::16, 2::16>>]} = ShellFrame.encode({:resize, 1, 2})

      for {cols, rows} <- [
            {0, 1},
            {1, 0},
            {0, 0},
            {65_536, 1},
            {1, 65_536},
            {1.0, 1},
            {1, 1.0},
            {1, -1}
          ] do
        assert ShellFrame.encode({:resize, cols, rows}) == {:error, :invalid_frame}
      end
    end

    test "exit takes one byte status" do
      for status <- [0, 1, 127, 255] do
        assert {:ok, [<<2, 0, 0, 0, 1>>, <<status>>]} = ShellFrame.encode({:exit, status})
      end

      for status <- [-1, 256, 1.0, "0", nil] do
        assert ShellFrame.encode({:exit, status}) == {:error, :invalid_frame}
      end
    end

    test "refuses frames that are not data, resize, or exit" do
      assert ShellFrame.encode({:other, <<>>}) == {:error, :invalid_frame}
      assert ShellFrame.encode(:data) == {:error, :invalid_frame}
      assert ShellFrame.encode(nil) == {:error, :invalid_frame}
    end
  end

  describe "decode/2" do
    test "decodes data in both directions" do
      assert ShellFrame.decode(frame(0, "hi"), :to_agent) == {:ok, [{:data, "hi"}], <<>>}
      assert ShellFrame.decode(frame(0, "hi"), :to_server) == {:ok, [{:data, "hi"}], <<>>}
    end

    test "resize is legal only toward the agent, and exit only toward the server" do
      resize = frame(1, <<80::16, 24::16>>)
      exit = frame(2, <<3>>)

      assert ShellFrame.decode(resize, :to_agent) == {:ok, [{:resize, 80, 24}], <<>>}
      assert ShellFrame.decode(exit, :to_server) == {:ok, [{:exit, 3}], <<>>}

      assert ShellFrame.decode(resize, :to_server) == {:error, :invalid_frame}
      assert ShellFrame.decode(exit, :to_agent) == {:error, :invalid_frame}
    end

    test "a resize with a zero dimension is refused" do
      assert ShellFrame.decode(frame(1, <<0::16, 24::16>>), :to_agent) == {:error, :invalid_frame}
      assert ShellFrame.decode(frame(1, <<80::16, 0::16>>), :to_agent) == {:error, :invalid_frame}
    end

    test "an exit payload that is not exactly one byte is refused" do
      assert ShellFrame.decode(frame(2, <<1, 2>>), :to_server) == {:error, :invalid_frame}
      assert ShellFrame.decode(frame(2, <<>>), :to_server) == {:error, :invalid_frame}
    end

    test "returns a partial frame untouched" do
      complete = IO.iodata_to_binary([frame(0, "hello"), frame(0, "world")])

      for length <- 0..(byte_size(complete) - 1) do
        partial = binary_part(complete, 0, length)
        assert {:ok, frames, rest} = ShellFrame.decode(partial, :to_server)
        assert is_list(frames)
        assert IO.iodata_to_binary([Enum.map(frames, &encode_frame/1), rest]) == partial
      end

      assert ShellFrame.decode(complete, :to_server) ==
               {:ok, [{:data, "hello"}, {:data, "world"}], <<>>}
    end

    test "rejects an oversized declared length from the header alone" do
      assert ShellFrame.decode(<<0, @max + 1::unsigned-big-32>>, :to_server) ==
               {:error, :frame_too_large}
    end

    test "accepts a payload exactly at the bound" do
      bytes = :binary.copy(<<7>>, @max)
      assert ShellFrame.decode(frame(0, bytes), :to_server) == {:ok, [{:data, bytes}], <<>>}
    end

    property "decoding arbitrary binaries never raises" do
      check all(buffer <- StreamData.binary(), direction <- member_of([:to_agent, :to_server])) do
        case ShellFrame.decode(buffer, direction) do
          {:ok, frames, rest} ->
            assert is_list(frames)
            assert is_binary(rest)

          {:error, reason} ->
            assert reason in [:frame_too_large, :invalid_frame]
        end
      end
    end

    property "every encoded frame decodes back to itself" do
      check all(frame <- frame_value(), direction <- member_of([:to_agent, :to_server])) do
        case ShellFrame.encode(frame) do
          {:ok, encoded} ->
            binary = IO.iodata_to_binary(encoded)

            case ShellFrame.decode(binary, direction) do
              {:ok, decoded, <<>>} -> assert decoded == [frame]
              {:error, :invalid_frame} -> assert not legal?(frame, direction)
            end

          {:error, :frame_too_large} ->
            assert match?({:data, payload} when byte_size(payload) > @max, frame)
        end
      end
    end
  end

  describe "reframe/2" do
    test "passes whole frames through and keeps a partial tail" do
      buffer = IO.iodata_to_binary([frame(0, "hello"), frame(1, <<80::16, 24::16>>), <<0, 0>>])

      assert {:ok, outgoing, <<0, 0>>} = ShellFrame.reframe(buffer, :to_agent)

      assert IO.iodata_to_binary(outgoing) ==
               IO.iodata_to_binary([frame(0, "hello"), frame(1, <<80::16, 24::16>>)])
    end

    test "stops at an exit frame that ends the buffer" do
      buffer = IO.iodata_to_binary([frame(0, "bye"), frame(2, <<0>>)])
      assert {:exit, outgoing} = ShellFrame.reframe(buffer, :to_server)
      assert IO.iodata_to_binary(outgoing) == buffer
    end

    test "an exit frame followed by anything at all is an error" do
      exit = frame(2, <<0>>)

      assert ShellFrame.reframe(exit <> IO.iodata_to_binary(frame(0, "x")), :to_server) ==
               {:error, :invalid_frame}

      assert ShellFrame.reframe(exit <> <<0>>, :to_server) == {:error, :invalid_frame}
    end

    test "a decode error is a reframe error" do
      assert ShellFrame.reframe(frame(2, <<0>>), :to_agent) == {:error, :invalid_frame}

      assert ShellFrame.reframe(<<0, 65_537::unsigned-big-32>>, :to_server) ==
               {:error, :frame_too_large}
    end

    property "reframe never raises for arbitrary binaries" do
      check all(buffer <- StreamData.binary(), direction <- member_of([:to_agent, :to_server])) do
        case ShellFrame.reframe(buffer, direction) do
          {:ok, outgoing, rest} ->
            assert is_binary(rest)
            assert is_list(outgoing)

          {:exit, outgoing} ->
            assert is_list(outgoing)

          {:error, reason} ->
            assert reason in [:frame_too_large, :invalid_frame]
        end
      end
    end

    property "one changed byte of a valid encoding never raises" do
      check all(
              buffer <- valid_reframe_buffer(),
              index <- integer(0..(byte_size(buffer) - 1)),
              replacement <- integer(0..255)
            ) do
        damaged =
          :binary.part(buffer, 0, index) <>
            <<replacement>> <> :binary.part(buffer, index + 1, byte_size(buffer) - index - 1)

        case ShellFrame.reframe(damaged, :to_server) do
          {:ok, _outgoing, _rest} -> :ok
          {:exit, _outgoing} -> :ok
          {:error, reason} -> assert reason in [:frame_too_large, :invalid_frame]
        end
      end
    end
  end

  defp legal?({:data, _}, _direction), do: true
  defp legal?({:resize, _, _}, :to_agent), do: true
  defp legal?({:exit, _}, :to_server), do: true
  defp legal?(_frame, _direction), do: false

  defp frame(type, payload) do
    <<type, byte_size(payload)::unsigned-big-32, payload::binary>>
  end

  defp encode_frame({:data, payload}), do: frame(0, payload)
  defp encode_frame({:resize, cols, rows}), do: frame(1, <<cols::16, rows::16>>)
  defp encode_frame({:exit, status}), do: frame(2, <<status>>)

  defp frame_value do
    one_of([
      map(binary(max_length: @max + 2), &{:data, &1}),
      map(integer(1..65_535), &{:resize, &1, 1}),
      map(integer(0..255), &{:exit, &1})
    ])
  end

  defp valid_reframe_buffer do
    gen all(
          data <- binary(max_length: 32),
          cols <- integer(1..65_535),
          rows <- integer(1..65_535)
        ) do
      IO.iodata_to_binary([frame(0, data), frame(1, <<cols::16, rows::16>>), frame(0, "tail")])
    end
  end
end
