defmodule BiotWeb.TerminalSocket do
  @moduledoc """
  Adapts one browser WebSocket to one admitted shell stream.

  The WebSock process is the stream owner. It registers through `Access.open_shell/3`, passes every
  process message through `Access.handle_owner_message/2`, and closes through `Access.close/1` on
  every transport termination path.
  """

  alias Biot.Protocol.{BiotId, ShellRequest}
  alias Biot.Server.Access
  alias Biot.Server.Authentication
  alias Biot.Server.Streams

  @behaviour WebSock

  @type state :: %{
          authentication: Authentication.t(),
          biot_id: BiotId.t(),
          client_address: :inet.ip_address(),
          request: ShellRequest.t(),
          stream: Streams.Stream.t() | nil
        }

  @impl WebSock
  @spec init(state()) :: WebSock.handle_result()
  def init(
        %{
          authentication: authentication,
          biot_id: biot_id,
          client_address: client_address,
          request: request
        } = state
      ) do
    Logger.metadata(client_address: client_address)

    case Access.open_shell(authentication, biot_id, request) do
      {:ok, stream} ->
        case Streams.ask(stream) do
          :ok -> {:ok, %{state | stream: stream}}
          {:error, _reason} -> close_stream(state, stream, :lost)
        end

      {:error, reason} ->
        stop_without_stream(state, reason)
    end
  end

  @impl WebSock
  @spec handle_in({binary(), opcode: :binary | :text}, state()) :: WebSock.handle_result()
  def handle_in({data, opcode: :binary}, %{stream: stream} = state) when is_binary(data) do
    case stream && Streams.write(stream, data) do
      :ok -> {:ok, state}
      _error -> close_stream(state, stream, :lost)
    end
  end

  def handle_in({data, opcode: :text}, %{stream: stream} = state) when is_binary(data) do
    case decode_resize(data) do
      {:ok, cols, rows} ->
        case stream && Streams.resize(stream, cols, rows) do
          :ok -> {:ok, state}
          _error -> close_stream(state, stream, :lost)
        end

      :error ->
        close_stream(state, stream, :malformed)
    end
  end

  @impl WebSock
  @spec handle_info(term(), state()) :: WebSock.handle_result()
  def handle_info(message, %{stream: stream} = state) do
    case stream && Access.handle_owner_message(stream, message) do
      {:closed, reason} -> stop_after_owner_close(state, reason)
      :ignored -> handle_stream_message(message, state)
      nil -> {:ok, state}
    end
  end

  @impl WebSock
  @spec terminate(WebSock.close_reason(), state()) :: any()
  def terminate(_reason, %{stream: nil}), do: :ok
  def terminate(_reason, %{stream: stream}), do: Access.close(stream)

  defp handle_stream_message(message, %{stream: stream} = state) do
    case Streams.stream(stream, message) do
      :unknown -> {:ok, state}
      {events, stream} -> handle_stream_events(events, %{state | stream: stream})
    end
  end

  defp handle_stream_events(events, state) do
    case emit_events(events, [], state) do
      {:continue, state} -> arm_stream(state, [])
      {:continue, messages, state} -> arm_stream(state, messages)
      result -> result
    end
  end

  defp emit_events([], [], state), do: {:continue, state}
  defp emit_events([], messages, state), do: {:continue, Enum.reverse(messages), state}

  defp emit_events([{:data, data} | events], messages, state),
    do: emit_events(events, [{:binary, data} | messages], state)

  defp emit_events([{:exit, status} | _events], messages, %{stream: stream} = state) do
    messages = [{:text, Jason.encode!(%{"exit" => status})} | messages]
    :ok = Access.close(stream)
    {:stop, :normal, 1000, Enum.reverse(messages), %{state | stream: nil}}
  end

  defp emit_events([:closed | _events], messages, %{stream: stream} = state),
    do: close_stream(state, stream, :closed, messages)

  defp emit_events([:lost | _events], messages, %{stream: stream} = state),
    do: close_stream(state, stream, :lost, messages)

  defp emit_events(_events, messages, state), do: emit_events([], messages, state)

  defp arm_stream(%{stream: stream} = state, messages) do
    case Streams.ask(stream) do
      :ok when messages == [] -> {:ok, state}
      :ok -> {:push, messages, state}
      {:error, _reason} -> close_stream(state, stream, :lost, Enum.reverse(messages))
    end
  end

  defp decode_resize(data) do
    with {:ok, value} <- Jason.decode(data),
         true <- is_map(value),
         true <- map_size(value) == 1,
         {:ok, resize} <- Map.fetch(value, "resize"),
         true <- is_map(resize),
         true <- map_size(resize) == 2,
         {:ok, cols} <- positive_dimension(Map.get(resize, "cols")),
         {:ok, rows} <- positive_dimension(Map.get(resize, "rows")) do
      {:ok, cols, rows}
    else
      _error -> :error
    end
  end

  defp positive_dimension(value) when is_integer(value) and value in 1..65_535,
    do: {:ok, value}

  defp positive_dimension(_value), do: :error

  defp stop_after_owner_close(state, reason) do
    {:stop, reason, close_detail(reason), %{state | stream: nil}}
  end

  defp stop_without_stream(state, reason) do
    {:stop, reason, close_detail(reason), %{state | stream: nil}}
  end

  defp close_stream(%{stream: nil} = state, _stream, reason),
    do: stop_without_stream(state, reason)

  defp close_stream(state, stream, reason), do: close_stream(state, stream, reason, [])

  defp close_stream(%{stream: stream} = state, stream, reason, messages) do
    :ok = Access.close(stream)

    case messages do
      [] ->
        {:stop, reason, close_detail(reason), %{state | stream: nil}}

      _messages ->
        {:stop, reason, close_detail(reason), Enum.reverse(messages), %{state | stream: nil}}
    end
  end

  defp close_detail(:normal), do: 1000
  defp close_detail(:closed), do: 1000
  defp close_detail(:policy), do: {1008, "policy-closed"}
  defp close_detail(:expired), do: {1008, "expired"}
  defp close_detail(:control_lost), do: {1011, "lost"}
  defp close_detail(:forbidden), do: {1008, "policy-closed"}
  defp close_detail(:unauthenticated), do: {1008, "expired"}
  defp close_detail(:malformed), do: {1003, "malformed"}
  defp close_detail(:not_found), do: {1008, "closed"}
  defp close_detail(:node_unavailable), do: {1011, "lost"}
  defp close_detail(:agent_unreachable), do: {1011, "lost"}
  defp close_detail(:port_not_listening), do: {1011, "lost"}
  defp close_detail(:too_many_streams), do: {1013, "closed"}
  defp close_detail(:timeout), do: {1013, "closed"}
  defp close_detail(:lost), do: {1011, "lost"}
  defp close_detail(_reason), do: {1011, "closed"}
end
