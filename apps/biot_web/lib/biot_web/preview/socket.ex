defmodule BiotWeb.Preview.Socket do
  @moduledoc """
  Adapts one browser WebSocket to one admitted preview port stream.

  The process is the stream owner. It performs the upstream handshake, then relays frames in both
  directions through `BiotWeb.Preview.WebSocket`. Every exit path closes the stream through
  `Access.close/1`: a browser disconnect, an application close frame, a lost control connection,
  or a policy revocation arriving through `Access.handle_owner_message/2`.
  """

  @behaviour WebSock

  alias Biot.Server.Access
  alias Biot.Server.Authentication
  alias Biot.Server.Streams
  alias BiotWeb.Preview.{Limits, Response, WebSocket}

  @websocket_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  @type state :: %{
          authentication: Authentication.t(),
          hostname: Biot.Protocol.Hostname.t(),
          handshake: iodata(),
          key: String.t() | nil,
          stream: Streams.Stream.t() | nil,
          codec: WebSocket.t()
        }

  @impl WebSock
  def init(options) do
    state = %{codec: WebSocket.new(WebSocket.max_bytes()), stream: nil}

    case Access.open_preview(options.authentication, options.hostname) do
      {:ok, stream} -> start(stream, Map.merge(state, options))
      {:error, reason} -> {:stop, reason, close_detail(reason), state}
    end
  end

  defp start(stream, state) do
    state = %{state | stream: stream}

    with :ok <- Streams.write(stream, state.handshake),
         {:ok, response, leftover} <- read_head(stream),
         :ok <- validate_upgrade(response, state.key) do
      case WebSocket.decode(state.codec, leftover) do
        {:ok, events, codec} -> open(%{state | codec: codec}, events)
        {:error, _reason} -> stop(state, :protocol_error)
      end
    else
      {:error, _reason} -> stop(state, :upgrade_failed)
    end
  end

  defp open(state, events) do
    case messages(events) do
      {:ok, messages} -> arm(state, messages)
      {:close, messages, detail} -> close_with(state, messages, detail)
    end
  end

  @impl WebSock
  def handle_in({payload, opcode: opcode}, state) when opcode in [:text, :binary] do
    write(state, opcode, payload)
  end

  @impl WebSock
  # Bandit already answered the browser's ping, and Biot answers the application's pings, so no
  # control frame crosses the tunnel.
  def handle_control({_payload, opcode: opcode}, state) when opcode in [:ping, :pong] do
    {:ok, state}
  end

  @impl WebSock
  def handle_info(message, state) do
    case Access.handle_owner_message(state.stream, message) do
      {:closed, reason} -> stop(state, reason)
      :ignored -> stream_message(state, message)
    end
  end

  @impl WebSock
  def terminate(_reason, %{stream: nil}), do: :ok
  def terminate(_reason, %{stream: stream}), do: Access.close(stream)

  defp write(state, opcode, payload) do
    case WebSocket.encode(state.codec, opcode, payload) do
      {:ok, frame} -> send_frame(state, frame)
      {:error, _reason} -> stop(state, :protocol_error)
    end
  end

  defp send_frame(state, frame) do
    case Streams.write(state.stream, frame) do
      :ok -> {:ok, state}
      {:error, _reason} -> stop(state, :lost)
    end
  end

  defp stream_message(state, message) do
    case Streams.stream(state.stream, message) do
      :unknown -> {:ok, state}
      {events, stream} -> handle_events(events, %{state | stream: stream})
    end
  end

  defp handle_events(events, state) do
    case fold_events(events, state, []) do
      {:ok, messages, state} -> arm(state, messages)
      {:close, reversed, detail, state} -> close_with(state, Enum.reverse(reversed), detail)
      {:error, reason, state} -> stop(state, reason)
    end
  end

  defp fold_events([], state, messages), do: {:ok, Enum.reverse(messages), state}

  defp fold_events([{:data, data} | rest], state, messages) do
    case WebSocket.decode(state.codec, data) do
      {:ok, events, codec} -> collect(events, %{state | codec: codec}, rest, messages)
      {:error, _reason} -> {:error, :protocol_error, state}
    end
  end

  # A TCP close without an application close frame is not a clean WebSocket close.
  defp fold_events([:closed | _rest], state, _messages), do: {:close, [], :default, state}
  defp fold_events([:lost | _rest], state, _messages), do: {:close, [], {:code, 1011, ""}, state}

  defp collect(events, state, rest, messages) do
    case answer_pings(events, state) do
      :ok -> append_messages(events, state, rest, messages)
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp append_messages(events, state, rest, messages) do
    case messages(events) do
      {:ok, new_messages} ->
        fold_events(rest, state, Enum.reverse(new_messages, messages))

      {:close, new_messages, detail} ->
        {:close, Enum.reverse(new_messages, messages), detail, state}
    end
  end

  # The application's pings are answered here rather than carried to the browser, so the tunnel
  # produces no control traffic the application did not send.
  defp answer_pings(events, state) do
    events
    |> Enum.filter(&match?({:ping, _payload}, &1))
    |> Enum.reduce_while(:ok, fn {:ping, payload}, :ok -> answer_ping(state, payload) end)
  end

  defp answer_ping(state, payload) do
    case WebSocket.encode(state.codec, :pong, payload) do
      {:ok, frame} -> answer_frame(state, frame)
      {:error, _reason} -> {:halt, {:error, :protocol_error}}
    end
  end

  defp answer_frame(state, frame) do
    case Streams.write(state.stream, frame) do
      :ok -> {:cont, :ok}
      {:error, _reason} -> {:halt, {:error, :lost}}
    end
  end

  # The browser side is framed by Bandit and gives whole messages; only the application side is
  # ours to reassemble, and `WebSocket` bounds that.
  defp messages(events), do: messages(events, [])

  defp messages([], messages), do: {:ok, Enum.reverse(messages)}

  defp messages([{:data, opcode, payload} | rest], messages),
    do: messages(rest, [{opcode, payload} | messages])

  defp messages([{:ping, _payload} | rest], messages), do: messages(rest, messages)
  defp messages([{:pong, _payload} | rest], messages), do: messages(rest, messages)

  defp messages([{:close, nil, _reason} | _rest], messages),
    do: {:close, Enum.reverse(messages), :default}

  defp messages([{:close, code, reason} | _rest], messages),
    do: {:close, Enum.reverse(messages), {:code, code, reason}}

  defp arm(state, messages) do
    case Streams.ask(state.stream) do
      :ok when messages == [] -> {:ok, state}
      :ok -> {:push, messages, state}
      {:error, _reason} -> stop(state, :lost)
    end
  end

  # The application's own close code and reason are forwarded; a close with none keeps the
  # adapter's default rather than inventing a code.
  defp close_with(state, messages, :default) when messages == [] do
    _ = Access.close(state.stream)
    {:stop, :normal, %{state | stream: nil}}
  end

  defp close_with(state, messages, :default) do
    _ = Access.close(state.stream)
    {:stop, :normal, 1000, messages, %{state | stream: nil}}
  end

  defp close_with(state, messages, {:code, code, reason}) when messages == [] do
    _ = Access.close(state.stream)
    {:stop, :normal, {code, reason}, %{state | stream: nil}}
  end

  defp close_with(state, messages, {:code, code, reason}) do
    _ = Access.close(state.stream)
    {:stop, :normal, {code, reason}, messages, %{state | stream: nil}}
  end

  defp stop(state, reason) do
    _ = Access.close(state.stream)
    {:stop, reason, close_detail(reason), %{state | stream: nil}}
  end

  defp read_head(stream), do: read_head(stream, <<>>)

  defp read_head(stream, buffer) do
    case Response.parse_head(buffer, Limits.head_max_bytes()) do
      {:ok, response, rest} ->
        {:ok, response, rest}

      :more ->
        if byte_size(buffer) > Limits.head_max_bytes(),
          do: {:error, :head_too_large},
          else: await_head(stream, buffer)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp await_head(stream, buffer) do
    case Streams.ask(stream) do
      :ok ->
        receive do
          message -> consume_head(stream, buffer, message)
        after
          Limits.handshake_timeout_ms() -> {:error, :timeout}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp consume_head(stream, buffer, message) do
    case Access.handle_owner_message(stream, message) do
      {:closed, _reason} ->
        {:error, :closed}

      :ignored ->
        case Streams.stream(stream, message) do
          :unknown -> await_head(stream, buffer)
          {events, _stream} -> consume_head_events(events, stream, buffer)
        end
    end
  end

  defp consume_head_events(events, stream, buffer) do
    case append_data(events, buffer) do
      {:ok, buffer} -> read_head(stream, buffer)
      :closed -> {:error, :closed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_data([], buffer), do: {:ok, buffer}
  defp append_data([{:data, data} | rest], buffer), do: append_data(rest, buffer <> data)
  defp append_data([:closed | _rest], _buffer), do: :closed
  defp append_data([:lost | _rest], _buffer), do: {:error, :lost}

  defp validate_upgrade(%Response{status: 101, headers: headers}, key) do
    with true <- header_contains?(headers, "upgrade", "websocket"),
         true <- header_contains?(headers, "connection", "upgrade"),
         true <- header_value(headers, "sec-websocket-accept") == accept(key) do
      :ok
    else
      _mismatch -> {:error, :invalid_upgrade}
    end
  end

  defp validate_upgrade(_response, _key), do: {:error, :invalid_upgrade}

  defp header_contains?(headers, name, needle) do
    case header_value(headers, name) do
      nil -> false
      value -> String.contains?(String.downcase(value), needle)
    end
  end

  defp header_value(headers, name) do
    Enum.find_value(headers, fn {header_name, value} ->
      if header_name == name, do: value
    end)
  end

  defp accept(nil), do: nil

  defp accept(key) when is_binary(key) do
    Base.encode64(:crypto.hash(:sha, key <> @websocket_guid))
  end

  defp close_detail(:policy), do: {1008, "policy-closed"}
  defp close_detail(:expired), do: {1008, "expired"}
  defp close_detail(:control_lost), do: {1011, "lost"}
  defp close_detail(:closed), do: {1000, "closed"}
  defp close_detail(:lost), do: {1011, "lost"}
  defp close_detail(:forbidden), do: {1008, "policy-closed"}
  defp close_detail(:unauthenticated), do: {1008, "expired"}
  defp close_detail(:not_found), do: {1008, "closed"}
  defp close_detail(:node_unavailable), do: {1011, "lost"}
  defp close_detail(:agent_unreachable), do: {1011, "lost"}
  defp close_detail(:port_not_listening), do: {1011, "lost"}
  defp close_detail(:too_many_streams), do: {1013, "closed"}
  defp close_detail(:timeout), do: {1013, "closed"}
  defp close_detail(:protocol_error), do: {1002, "protocol"}
  defp close_detail(:upgrade_failed), do: {1011, "upgrade"}
end
