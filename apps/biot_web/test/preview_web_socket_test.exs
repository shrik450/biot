defmodule BiotWeb.PreviewWebSocketTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BiotWeb.Preview.WebSocket

  @max 64

  property "decoding arbitrary bytes is total and bounded" do
    check all(bytes <- StreamData.binary(max_length: 4_096), max_runs: 200) do
      task = Task.async(fn -> WebSocket.decode(WebSocket.new(@max), bytes) end)

      result = Task.await(task, 500)

      assert match?({:ok, _events, %WebSocket{}}, result) or match?({:error, _reason}, result)
    end
  end

  test "every truncation of a valid frame remains incremental" do
    frame = server_frame(0x2, :binary.copy(<<0xA5>>, 32))

    for length <- 0..(byte_size(frame) - 1) do
      prefix = binary_part(frame, 0, length)
      assert {:ok, events, state} = WebSocket.decode(WebSocket.new(@max), prefix)
      assert events == []
      assert state.buffer == prefix
    end

    assert {:ok, [{:data, :binary, payload}], %WebSocket{buffer: <<>>}} =
             WebSocket.decode(WebSocket.new(@max), frame)

    assert payload == :binary.copy(<<0xA5>>, 32)
  end

  test "declared lengths are rejected before payload allocation" do
    assert WebSocket.decode(WebSocket.new(@max), <<0x82, 65>>) ==
             {:error, :frame_too_large}

    assert WebSocket.decode(WebSocket.new(@max), <<0x82, 126, 0, 65>>) ==
             {:error, :frame_too_large}

    assert WebSocket.decode(WebSocket.new(@max), <<0x82, 127, 0x80, 0, 0, 0, 0, 0, 0, 1>>) ==
             {:error, :invalid_frame}

    assert WebSocket.decode(WebSocket.new(@max), <<0x82, 127, 0x80, 0, 0, 0, 0, 0, 0, 0>>) ==
             {:error, :invalid_frame}

    assert {:ok, [{:data, :binary, payload}], %WebSocket{buffer: <<>>}} =
             WebSocket.decode(WebSocket.new(@max), server_frame(0x2, :binary.copy(<<7>>, @max)))

    assert byte_size(payload) == @max
  end

  test "fragmented messages are reassembled and an unfinished message stays pending" do
    complete =
      server_frame(0x1, "hel", fin: 0) <>
        server_frame(0x0, "lo", fin: 0) <>
        server_frame(0x0, "!", fin: 1)

    assert {:ok, [{:data, :text, "hello!"}], %WebSocket{fragment: nil}} =
             WebSocket.decode(WebSocket.new(@max), complete)

    unfinished = server_frame(0x1, "hel", fin: 0) <> server_frame(0x0, "lo", fin: 0)

    assert {:ok, [], %WebSocket{fragment: %{size: 5}}} =
             WebSocket.decode(WebSocket.new(@max), unfinished)
  end

  test "fragmented message size accumulates at the exact limit and over it" do
    exact =
      server_frame(0x1, "a", fin: 0) <>
        Enum.map_join(1..62, fn _ -> server_frame(0x0, "a", fin: 0) end) <>
        server_frame(0x0, "a", fin: 1)

    assert {:ok, [{:data, :text, payload}], _state} = WebSocket.decode(WebSocket.new(@max), exact)
    assert byte_size(payload) == @max

    over =
      server_frame(0x1, "a", fin: 0) <>
        Enum.map_join(1..63, fn _ -> server_frame(0x0, "a", fin: 0) end) <>
        server_frame(0x0, "a", fin: 1)

    assert WebSocket.decode(WebSocket.new(@max), over) == {:error, :message_too_large}
  end

  test "empty continuations do not retain an unbounded chunk list" do
    bytes =
      server_frame(0x1, <<>>, fin: 0) <>
        Enum.map_join(1..50_000, fn _ -> server_frame(0x0, <<>>, fin: 0) end)

    task = Task.async(fn -> WebSocket.decode(WebSocket.new(@max), bytes) end)

    assert {:ok, [], %WebSocket{fragment: %{chunks: [], size: 0}}} = Task.await(task, 1_000)
  end

  test "control frames can interrupt a fragmented message" do
    bytes =
      server_frame(0x1, "a", fin: 0) <>
        server_frame(0x9, "heartbeat") <>
        server_frame(0x0, "b", fin: 1)

    assert {:ok, [{:ping, "heartbeat"}, {:data, :text, "ab"}], _state} =
             WebSocket.decode(WebSocket.new(@max), bytes)
  end

  test "reserved bits and unknown opcodes are refused" do
    assert WebSocket.decode(WebSocket.new(@max), <<0xC2, 0>>) == {:error, :invalid_rsv}
    assert WebSocket.decode(WebSocket.new(@max), <<0x83, 0>>) == {:error, :invalid_opcode}

    assert WebSocket.decode(WebSocket.new(@max), <<0x00, 0>>) ==
             {:error, :unexpected_continuation}
  end

  test "close payload forms follow the protocol boundary" do
    assert {:ok, [{:close, nil, <<>>}], _state} =
             WebSocket.decode(WebSocket.new(@max), server_frame(0x8, <<>>))

    assert WebSocket.decode(WebSocket.new(@max), server_frame(0x8, <<1>>)) ==
             {:error, :invalid_close_payload}

    reason = :binary.copy("r", @max - 2)

    assert {:ok, [{:close, 1000, ^reason}], _state} =
             WebSocket.decode(
               WebSocket.new(@max),
               server_frame(0x8, <<1000::16, reason::binary>>)
             )
  end

  property "every application payload is forwarded byte-identically" do
    check all(
            payload <- StreamData.binary(max_length: @max),
            opcode <- StreamData.member_of([0x1, 0x2]),
            max_runs: 200
          ) do
      frame = server_frame(opcode, payload)

      assert {:ok, [{:data, decoded_opcode, ^payload}], %WebSocket{buffer: <<>>}} =
               WebSocket.decode(WebSocket.new(@max), frame)

      assert decoded_opcode == if(opcode == 0x1, do: :text, else: :binary)
    end
  end

  test "control frame encoding has its own 125-byte payload limit" do
    codec = WebSocket.new(200)

    assert WebSocket.encode(codec, :ping, :binary.copy(<<0>>, 125)) |> elem(0) == :ok

    assert WebSocket.encode(codec, :pong, :binary.copy(<<0>>, 126)) ==
             {:error, :frame_too_large}
  end

  test "control frame decoding accepts 125 bytes and rejects oversized or fragmented frames" do
    codec = WebSocket.new(200)
    payload = :binary.copy(<<0>>, 125)

    assert {:ok, [{:ping, ^payload}], _state} =
             WebSocket.decode(codec, server_frame(0x9, payload))

    assert WebSocket.decode(codec, server_frame(0x9, :binary.copy(<<0>>, 126))) ==
             {:error, :invalid_control_frame}

    assert WebSocket.decode(codec, server_frame(0x9, <<>>, fin: 0)) ==
             {:error, :invalid_control_frame}
  end

  defp server_frame(opcode, payload, options \\ []) do
    fin = Keyword.get(options, :fin, 1)
    size = byte_size(payload)

    cond do
      size <= 125 -> <<fin::1, 0::3, opcode::4, 0::1, size::7, payload::binary>>
      size <= 65_535 -> <<fin::1, 0::3, opcode::4, 0::1, 126::7, size::16, payload::binary>>
      true -> <<fin::1, 0::3, opcode::4, 0::1, 127::7, size::64, payload::binary>>
    end
  end
end
