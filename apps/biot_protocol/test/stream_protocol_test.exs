defmodule Biot.Protocol.StreamProtocolTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Biot.Protocol.AgentReply
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.ConnectionId
  alias Biot.Protocol.Frame
  alias Biot.Protocol.Limits
  alias Biot.Protocol.Message
  alias Biot.Protocol.Port
  alias Biot.Protocol.RegistrationId
  alias Biot.Protocol.ShellRequest
  alias Biot.Protocol.StreamFailure
  alias Biot.Protocol.StreamId
  alias Biot.Protocol.StreamTarget
  alias Biot.Protocol.TestGenerators, as: Generators
  alias Biot.Protocol.Wire

  @stream_id "11111111-2222-4333-8444-555555555555"
  @connection_id "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
  @biot_id "99999999-8888-4777-8666-555555555555"
  @registration_id "12345678-1234-4123-8123-123456789012"

  defp stream_id, do: elem(StreamId.parse(@stream_id), 1)
  defp connection_id, do: elem(ConnectionId.parse(@connection_id), 1)
  defp biot_id, do: elem(BiotId.parse(@biot_id), 1)
  defp registration_id, do: elem(RegistrationId.parse(@registration_id), 1)
  defp port(value), do: elem(Port.parse(value), 1)

  describe "StreamId" do
    test "parses only canonical lower-case UUID strings" do
      assert {:ok, %StreamId{value: @stream_id}} = StreamId.parse(@stream_id)

      for value <- [
            "11111111-2222-4333-8444-55555555555",
            "11111111-2222-4333-8444-5555555555555",
            "11111111-2222-4333-8444-55555555555g",
            "11111111-2222-3333-8444-555555555555",
            "11111111-2222-4333-7444-555555555555",
            "11111111-2222-4333-8444-55555555555A",
            "11111111-2222-4333-8444-555555555555\n",
            :not_a_binary,
            nil,
            42,
            ["11111111-2222-4333-8444-555555555555"]
          ] do
        assert StreamId.parse(value) == {:error, :invalid_format}
      end
    end

    test "round-trips through its string form" do
      id = stream_id()
      assert StreamId.to_string(id) == @stream_id
      assert to_string(id) == @stream_id
    end

    property "StreamId.parse never raises for arbitrary terms" do
      check all(value <- Generators.non_binary_term(), binary <- StreamData.binary()) do
        assert_parse_value(StreamId, value)
        assert_parse_value(StreamId, binary)
      end
    end
  end

  describe "StreamTarget" do
    test "port targets round-trip through the agent encoding" do
      target = {:port, port(3000)}
      assert StreamTarget.kind(target) == :port
      assert StreamTarget.encode(target) == %{"target" => "port", "port" => 3000}
      assert StreamTarget.parse(%{"target" => "port", "port" => 3000}) == {:ok, target}
    end

    test "shell targets round-trip through the agent encoding" do
      request = %ShellRequest{
        term: "xterm-256color",
        cols: 120,
        rows: 40,
        command: ["sh", "-c", "true"]
      }

      target = {:shell, request}
      assert StreamTarget.kind(target) == :shell

      assert StreamTarget.encode(target) == %{
               "target" => "shell",
               "term" => "xterm-256color",
               "cols" => 120,
               "rows" => 40,
               "command" => ["sh", "-c", "true"]
             }

      assert StreamTarget.parse(StreamTarget.encode(target)) == {:ok, target}
    end

    test "rejects maps the agent would reject: wrong keys, wrong types, unknown targets" do
      for value <- [
            %{},
            %{"target" => "port"},
            %{"target" => "port", "port" => 3000, "extra" => 1},
            %{"target" => "port", "port" => 0},
            %{"target" => "port", "port" => 65_536},
            %{"target" => "port", "port" => 3000.0},
            %{"target" => "shell", "term" => "x", "cols" => 80, "rows" => 24},
            %{
              "target" => "shell",
              "term" => "x",
              "cols" => 80,
              "rows" => 24,
              "command" => nil,
              "x" => 1
            },
            %{"target" => "shell", "term" => "", "cols" => 80, "rows" => 24, "command" => nil},
            %{"target" => "shell", "term" => "x", "cols" => 0, "rows" => 24, "command" => nil},
            %{"target" => "shell", "term" => "x", "cols" => 80, "rows" => 24, "command" => []},
            %{"target" => "other"},
            "port",
            nil
          ] do
        assert StreamTarget.parse(value) == {:error, :invalid_format}
      end
    end

    test "rejects a target whose agent line would not fit the agent's 16 KiB buffer" do
      limit = Limits.max_agent_line_bytes()
      fit = fit_term(limit)
      assert {:ok, {:shell, %ShellRequest{term: ^fit}}} = StreamTarget.parse(shell_map(fit))
      assert StreamTarget.parse(shell_map(fit <> "x")) == {:error, :invalid_format}
    end

    test "returns an error, never raises, for a field that is not valid UTF-8" do
      assert StreamTarget.parse(shell_map(<<0xFF, 0xFE>>)) == {:error, :invalid_format}
      assert StreamTarget.parse(shell_map("x", command: [<<0xFF>>])) == {:error, :invalid_format}
    end

    property "StreamTarget.parse never raises for arbitrary terms" do
      check all(value <- Generators.non_binary_term(), binary <- StreamData.binary()) do
        assert_parse_value(StreamTarget, value)
        assert_parse_value(StreamTarget, binary)
      end
    end

    property "StreamTarget.parse never raises when one part of a valid encoding is replaced" do
      check all(
              target <- one_of([port_target(), shell_target()]),
              replacement <- json_term(),
              remove? <- StreamData.boolean()
            ) do
        map = StreamTarget.encode(target)
        field = Enum.random(Map.keys(map))
        damaged = if remove?, do: Map.delete(map, field), else: Map.put(map, field, replacement)
        assert_parse_value(StreamTarget, damaged)
      end
    end
  end

  describe "ShellRequest" do
    # One-way: every value ShellRequest.parse/1 accepts, the Go agent's parseShell also accepts.
    # The node may be stricter, so a value Go accepts is not required to parse here; every value
    # Go rejects must be rejected.
    test "accepts only what the Go agent's parseShell accepts" do
      accepted = [
        %{"term" => "xterm", "cols" => 80, "rows" => 24, "command" => nil},
        %{"term" => "xterm", "cols" => 65_535, "rows" => 1, "command" => ["a"]},
        %{"term" => "xterm", "cols" => 1, "rows" => 65_535, "command" => [""]}
      ]

      rejected = [
        %{"term" => "", "cols" => 80, "rows" => 24, "command" => nil},
        %{"term" => <<0>>, "cols" => 80, "rows" => 24, "command" => nil},
        %{"term" => "x", "cols" => 0, "rows" => 24, "command" => nil},
        %{"term" => "x", "cols" => 80, "rows" => 0, "command" => nil},
        %{"term" => "x", "cols" => 65_536, "rows" => 24, "command" => nil},
        %{"term" => "x", "cols" => -1, "rows" => 24, "command" => nil},
        %{"term" => "x", "cols" => 1.5, "rows" => 24, "command" => nil},
        %{"term" => "x", "cols" => "80", "rows" => 24, "command" => nil},
        %{"term" => "x", "cols" => 80, "rows" => 24, "command" => []},
        %{"term" => "x", "cols" => 80, "rows" => 24, "command" => [<<0>>]},
        %{"term" => "x", "cols" => 80, "rows" => 24, "command" => [1]},
        %{"term" => "x", "cols" => 80, "rows" => 24, "command" => "x"},
        %{"term" => "x", "cols" => 80, "rows" => 24, "command" => 5},
        %{"term" => "x", "cols" => 80, "rows" => 24, "command" => %{}},
        %{"term" => "x", "cols" => 80, "rows" => 24},
        %{"term" => "x", "cols" => 80, "rows" => 24, "command" => nil, "extra" => 1},
        %{"term" => 5, "cols" => 80, "rows" => 24, "command" => nil},
        %{"cols" => 80, "rows" => 24, "command" => nil}
      ]

      for value <- accepted do
        assert {:ok, %ShellRequest{}} = ShellRequest.parse(value)
      end

      for value <- rejected do
        assert ShellRequest.parse(value) == {:error, :invalid_format},
               "expected a rejection for #{inspect(value)}"
      end
    end

    test "rejects text that is not valid UTF-8" do
      assert ShellRequest.parse(%{
               "term" => <<0xFF>>,
               "cols" => 80,
               "rows" => 24,
               "command" => nil
             }) ==
               {:error, :invalid_format}

      assert ShellRequest.parse(%{
               "term" => <<0xFF, 0xFE>>,
               "cols" => 80,
               "rows" => 24,
               "command" => nil
             }) ==
               {:error, :invalid_format}

      assert ShellRequest.parse(%{
               "term" => "x",
               "cols" => 80,
               "rows" => 24,
               "command" => [<<0xFF>>]
             }) ==
               {:error, :invalid_format}
    end

    # A null is not a string, so the model's `list(string)` refuses it. The Go parser is more
    # lenient and turns it into "", which is harmless: this side never sends one.
    test "rejects a null command element" do
      assert ShellRequest.parse(%{
               "term" => "x",
               "cols" => 80,
               "rows" => 24,
               "command" => [nil]
             }) == {:error, :invalid_format}

      assert ShellRequest.parse(%{
               "term" => "x",
               "cols" => 80,
               "rows" => 24,
               "command" => ["a", nil]
             }) == {:error, :invalid_format}
    end

    test "encodes every field" do
      request = %ShellRequest{term: "xterm", cols: 80, rows: 24, command: ["sh", "-c", "echo hi"]}

      assert ShellRequest.encode(request) == %{
               "term" => "xterm",
               "cols" => 80,
               "rows" => 24,
               "command" => ["sh", "-c", "echo hi"]
             }
    end

    property "every request this parser accepts encodes to a line the agent accepts" do
      check all(request <- valid_shell_request()) do
        {:ok, parsed} = ShellRequest.parse(ShellRequest.encode(request))
        encoded = StreamTarget.encode({:shell, parsed})

        assert IO.iodata_length(Jason.encode_to_iodata!(encoded)) + 1 <=
                 Limits.max_agent_line_bytes()

        assert {:ok, {:shell, ^parsed}} = StreamTarget.parse(encoded)
      end
    end

    property "ShellRequest.parse never raises for arbitrary terms" do
      check all(value <- Generators.non_binary_term(), binary <- StreamData.binary()) do
        assert_parse_value(ShellRequest, value)
        assert_parse_value(ShellRequest, binary)
      end
    end

    property "ShellRequest.parse never raises when one part of a valid encoding is replaced" do
      check all(
              request <- valid_shell_request(),
              replacement <- json_term(),
              remove? <- StreamData.boolean()
            ) do
        map = ShellRequest.encode(request)
        field = Enum.random(Map.keys(map))
        damaged = if remove?, do: Map.delete(map, field), else: Map.put(map, field, replacement)
        assert_parse_value(ShellRequest, damaged)
      end
    end
  end

  describe "StreamFailure" do
    test "is the model's closed set, and to_string covers it" do
      assert StreamFailure.reasons() == [
               :unknown_biot,
               :stale_access,
               :agent_unreachable,
               :port_not_listening,
               :too_many_streams
             ]

      for reason <- StreamFailure.reasons() do
        assert StreamFailure.parse(StreamFailure.to_string(reason)) == {:ok, reason}
      end
    end

    test "rejects every string outside the closed set" do
      for value <- [
            "",
            "unknown",
            "stale",
            "unknown_stream",
            "UNKNOWN_BIOT",
            1,
            nil,
            :unknown_biot,
            ["stale_access"]
          ] do
        assert StreamFailure.parse(value) == {:error, :invalid_format}
      end
    end

    property "StreamFailure.parse never raises for arbitrary terms" do
      check all(value <- Generators.non_binary_term(), binary <- StreamData.binary()) do
        assert_parse_value(StreamFailure, value)
        assert_parse_value(StreamFailure, binary)
      end
    end
  end

  describe "AgentReply" do
    test "parses the agent's accepted and rejected replies" do
      assert AgentReply.parse(%{"ok" => true}) == {:ok, :ok}

      assert AgentReply.parse(%{"ok" => false, "error" => "connection_refused"}) ==
               {:ok, {:error, :connection_refused}}

      assert AgentReply.parse(%{"ok" => false, "error" => "invalid_request"}) ==
               {:ok, {:error, :invalid_request}}

      assert AgentReply.rejections() == [:invalid_request, :connection_refused]
    end

    test "rejects anything outside the closed set of replies" do
      for value <- [
            %{"ok" => false},
            %{"ok" => true, "error" => "connection_refused"},
            %{"ok" => false, "error" => "other"},
            %{"ok" => "true"},
            %{"ok" => false, "error" => 1},
            %{"ok" => true, "x" => 1},
            %{},
            [],
            "ok",
            nil
          ] do
        assert AgentReply.parse(value) == {:error, :invalid_format}
      end
    end

    property "AgentReply.parse never raises for arbitrary terms" do
      check all(value <- Generators.non_binary_term(), binary <- StreamData.binary()) do
        assert_parse_value(AgentReply, value)
        assert_parse_value(AgentReply, binary)
      end
    end
  end

  describe "Frame.take/2" do
    test "takes exactly one frame and leaves every byte after it untouched" do
      buffer = IO.iodata_to_binary([Frame.encode("one"), Frame.encode("two"), <<1, 2, 3>>])
      rest = IO.iodata_to_binary([Frame.encode("two"), <<1, 2, 3>>])
      assert Frame.take(buffer, 100) == {:ok, "one", rest}
    end

    test "returns :more until the whole frame has arrived" do
      frame = IO.iodata_to_binary(Frame.encode("payload"))

      for length <- 0..(byte_size(frame) - 1) do
        assert Frame.take(binary_part(frame, 0, length), 100) == :more
      end

      assert Frame.take(frame, 100) == {:ok, "payload", <<>>}
    end

    test "rejects an oversized header without waiting for its payload" do
      assert Frame.take(<<101::unsigned-big-32>>, 100) == {:error, :frame_too_large}

      assert Frame.take(<<101::unsigned-big-32, 0::size(101)-unit(8)>>, 100) ==
               {:error, :frame_too_large}
    end

    test "accepts a frame exactly at the bound" do
      frame = IO.iodata_to_binary(Frame.encode(:binary.copy(<<7>>, 100)))
      assert Frame.take(frame, 100) == {:ok, :binary.copy(<<7>>, 100), <<>>}
    end

    property "Frame.take/2 never raises for arbitrary binaries" do
      check all(buffer <- StreamData.binary(), max <- integer(1..10_000)) do
        case Frame.take(buffer, max) do
          {:ok, frame, rest} ->
            assert is_binary(rest)
            assert frame <> rest == buffer

          :more ->
            :ok

          {:error, :frame_too_large} ->
            :ok
        end
      end
    end
  end

  describe "Wire and the new messages" do
    test "every new message round-trips in its version" do
      for {context, message} <- new_messages() do
        assert {:ok, encoded} = Wire.encode(message, context)
        assert Wire.decode(encoded, context) == {:ok, message}
      end
    end

    test "the new version 1 messages are not handshake messages, and the handshake ones are not version 1" do
      for message <- [open_stream(), stream_failed()] do
        {:ok, encoded} = Wire.encode(message, 1)
        assert {:error, :invalid_message} = Wire.encode(message, :handshake)
        assert {:error, :unknown_message_type} = Wire.decode(encoded, :handshake)
      end

      for message <- [attach(), %Message.Attached{}] do
        {:ok, encoded} = Wire.encode(message, :handshake)
        assert {:error, :invalid_message} = Wire.encode(message, 1)
        assert {:error, :unknown_message_type} = Wire.decode(encoded, 1)
      end
    end

    test "every reject reason, including unknown_stream, round-trips" do
      assert :unknown_stream in Message.Reject.reasons()

      for reason <- Message.Reject.reasons() do
        reject = %Message.Reject{reason: reason}
        assert {:ok, encoded} = Wire.encode(reject, :handshake)
        assert Wire.decode(encoded, :handshake) == {:ok, reject}
      end
    end

    test "every stream failure reason round-trips inside stream_failed" do
      for reason <- StreamFailure.reasons() do
        message = %Message.StreamFailed{stream_id: stream_id(), reason: reason}
        assert {:ok, encoded} = Wire.encode(message, 1)
        assert {:ok, ^message} = Wire.decode(encoded, 1)
      end
    end

    test "an open_stream with a non-UTF-8 target encodes as an error, never raises" do
      target = {:shell, %ShellRequest{term: <<0xFF>>, cols: 80, rows: 24, command: nil}}
      message = %{open_stream() | target: target}

      assert {:error, reason} = Wire.encode(message, 1)
      assert is_atom(reason)
    end

    property "decoding a valid new message with one field changed never raises" do
      check all(
              {context, message} <- member_of(new_messages()),
              replacement <- json_term(),
              remove? <- StreamData.boolean()
            ) do
        {:ok, encoded} = Wire.encode(message, context)
        map = Jason.decode!(encoded)
        field = Enum.random(Map.keys(map))
        damaged = if remove?, do: Map.delete(map, field), else: Map.put(map, field, replacement)
        assert_wire_result(Jason.encode!(damaged), context)
      end
    end

    property "decoding random JSON values as a new message never raises" do
      check all(value <- json_term()) do
        assert_wire_result(Jason.encode!(value), 1)
        assert_wire_result(Jason.encode!(value), :handshake)
      end
    end
  end

  defp new_messages do
    [
      {1, open_stream()},
      {1,
       %{
         open_stream()
         | target: {:shell, %ShellRequest{term: "xterm", cols: 80, rows: 24, command: nil}}
       }},
      {1, stream_failed()},
      {:handshake, attach()},
      {:handshake, %Message.Attached{}}
    ]
  end

  defp open_stream do
    %Message.OpenStream{
      connection_id: connection_id(),
      access_revision: 7,
      stream_id: stream_id(),
      biot_id: biot_id(),
      target: {:port, port(8080)}
    }
  end

  defp stream_failed do
    %Message.StreamFailed{stream_id: stream_id(), reason: :too_many_streams}
  end

  defp attach do
    %Message.Attach{
      registration_id: registration_id(),
      connection_id: connection_id(),
      stream_id: stream_id()
    }
  end

  defp port_target do
    map(integer(1..65_535), fn value -> {:port, port(value)} end)
  end

  defp shell_target do
    gen all(
          term <- string(:printable, min_length: 1, max_length: 20),
          cols <- integer(1..65_535),
          rows <- integer(1..65_535),
          command <- member_of([nil, ["sh"], ["sh", "-c", "true"]])
        ) do
      {:shell, %ShellRequest{term: term, cols: cols, rows: rows, command: command}}
    end
  end

  defp valid_shell_request do
    gen all(
          term <- string(:printable, min_length: 1, max_length: 20),
          cols <- integer(1..65_535),
          rows <- integer(1..65_535),
          command <- member_of([nil, ["sh"], ["sh", "-c", "true"]])
        ) do
      %ShellRequest{term: term, cols: cols, rows: rows, command: command}
    end
  end

  defp shell_map(term, options \\ []) do
    %{
      "target" => "shell",
      "term" => term,
      "cols" => 80,
      "rows" => 24,
      "command" => Keyword.get(options, :command, nil)
    }
  end

  defp shell_request(term), do: %ShellRequest{term: term, cols: 80, rows: 24, command: nil}

  # The encoded shell line is a fixed-size envelope plus the term, so subtract that envelope and
  # fill the rest to build the largest term the agent's 16 KiB line buffer still holds.
  defp fit_term(limit) do
    candidate = "x"
    size_of = fn term -> encoded_size(shell_request(term)) end
    String.duplicate("x", limit - 1 - (size_of.(candidate) - byte_size(candidate)))
  end

  defp encoded_size(request) do
    request
    |> then(&StreamTarget.encode({:shell, &1}))
    |> Jason.encode_to_iodata!()
    |> IO.iodata_length()
  end

  defp assert_wire_result(value, context) do
    case Wire.decode(value, context) do
      {:ok, _message} -> :ok
      {:error, reason} when is_atom(reason) -> :ok
      {:error, {:invalid_message, _field}} -> :ok
      other -> flunk("Wire.decode returned #{inspect(other)}")
    end
  end

  defp assert_parse_value(module, value) do
    case module.parse(value) do
      {:ok, _parsed} ->
        :ok

      {:error, reason} when is_atom(reason) ->
        :ok

      other ->
        flunk("#{inspect(module)}.parse/1 returned #{inspect(other)} for #{inspect(value)}")
    end
  end

  defp json_term do
    one_of([
      integer(),
      float(),
      boolean(),
      constant(nil),
      string(:printable),
      list_of(integer(), max_length: 3),
      map_of(string(:alphanumeric, min_length: 1), integer(), max_length: 3)
    ])
  end
end
