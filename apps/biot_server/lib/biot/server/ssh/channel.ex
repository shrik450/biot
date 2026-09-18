defmodule Biot.Server.Ssh.Channel do
  @moduledoc """
  One SSH session channel as a session owner.

  Each channel admits itself again through `Access.open_shell/3`, so a revoked shell grant denies
  the next channel even while the SSH connection stays open. `window-change` becomes a resize, and
  the agent's exit status becomes the channel's exit status. The client's EOF is forwarded to the PTY
  as the terminal EOF byte, and a stream that closes without an agent exit frame is a lost session,
  never a success.
  """

  @behaviour :ssh_server_channel

  require Logger

  alias Biot.Protocol.{BiotId, ShellRequest}
  alias Biot.Server.Access
  alias Biot.Server.Authentication
  alias Biot.Server.Ssh.{Authentications, Command}
  alias Biot.Server.Streams

  @default_term "xterm-256color"
  @default_cols 80
  @default_rows 24
  @lost_status 255

  @type state :: %{
          connection: term() | nil,
          channel: non_neg_integer() | nil,
          authentication: Authentication.t() | nil,
          biot_id: BiotId.t() | nil,
          term: String.t(),
          cols: pos_integer(),
          rows: pos_integer(),
          stream: Streams.Stream.t() | nil
        }

  @impl true
  def init(_options) do
    {:ok,
     %{
       connection: nil,
       channel: nil,
       authentication: nil,
       biot_id: nil,
       term: @default_term,
       cols: @default_cols,
       rows: @default_rows,
       stream: nil
     }}
  end

  @impl true
  def handle_msg({:ssh_channel_up, channel_id, connection}, state) do
    with {:user, user} <- :ssh.connection_info(connection, :user),
         {:ok, biot_id} <- user_biot(user),
         %Authentication{} = authentication <- Authentications.authentication(connection) do
      {:ok,
       %{
         state
         | channel: channel_id,
           connection: connection,
           authentication: authentication,
           biot_id: biot_id
       }}
    else
      _rejected -> {:stop, channel_id, state}
    end
  end

  def handle_msg(message, %{stream: stream} = state) when not is_nil(stream) do
    case Access.handle_owner_message(stream, message) do
      {:closed, _reason} -> close_channel(state)
      :ignored -> stream_message(state, message)
    end
  end

  def handle_msg(_message, state), do: {:ok, state}

  @impl true
  def handle_ssh_msg(
        {:ssh_cm, connection, {:pty, channel, want_reply, {term, cols, rows, _, _, _}}},
        state
      ) do
    state = %{
      state
      | term: to_string(term),
        cols: positive(cols, @default_cols),
        rows: positive(rows, @default_rows)
    }

    :ssh_connection.reply_request(connection, want_reply, :success, channel)
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _connection, {:window_change, _channel, cols, rows, _, _}}, state) do
    cols = positive(cols, state.cols)
    rows = positive(rows, state.rows)

    case resize(state, cols, rows) do
      :ok -> {:ok, %{state | cols: cols, rows: rows}}
      {:error, _reason} -> lost_channel(state)
    end
  end

  def handle_ssh_msg({:ssh_cm, connection, {:shell, channel, want_reply}}, state) do
    open(state, connection, channel, want_reply, nil)
  end

  def handle_ssh_msg({:ssh_cm, connection, {:exec, channel, want_reply, command}}, state) do
    case Command.parse(to_string(command)) do
      {:ok, arguments} -> open(state, connection, channel, want_reply, arguments)
      {:error, :invalid_command} -> reject(connection, channel, want_reply, state)
    end
  end

  def handle_ssh_msg({:ssh_cm, _connection, {:data, _channel, _type, data}}, state) do
    write(state, data)
  end

  # The agent's shell is a PTY and the agent protocol has no separate input-EOF frame, so the
  # terminal EOF byte is how Biot tells the shell that the client's stdin closed.
  def handle_ssh_msg({:ssh_cm, _connection, {:eof, _channel}}, state), do: send_input_eof(state)

  def handle_ssh_msg({:ssh_cm, _connection, _event}, state), do: {:ok, state}

  @impl true
  def terminate(_reason, %{stream: nil}), do: :ok
  def terminate(_reason, %{stream: stream}), do: Access.close(stream)

  defp open(state, connection, channel, want_reply, command) do
    request = %ShellRequest{
      term: state.term,
      cols: state.cols,
      rows: state.rows,
      command: command
    }

    case Access.open_shell(state.authentication, state.biot_id, request) do
      {:ok, stream} ->
        case Streams.ask(stream) do
          :ok ->
            :ssh_connection.reply_request(connection, want_reply, :success, channel)
            {:ok, %{state | stream: stream, channel: channel, connection: connection}}

          {:error, reason} ->
            _ = Access.close(stream)
            log_open_failure(state, reason)
            reject(connection, channel, want_reply, state)
        end

      {:error, reason} ->
        log_open_failure(state, reason)
        reject(connection, channel, want_reply, state)
    end
  end

  defp write(%{stream: nil} = state, _data), do: {:ok, state}

  defp write(state, data) do
    case Streams.write(state.stream, data) do
      :ok -> {:ok, state}
      {:error, _reason} -> lost_channel(state)
    end
  end

  defp send_input_eof(%{stream: nil} = state), do: {:ok, state}

  defp send_input_eof(state) do
    case Streams.write(state.stream, <<4>>) do
      :ok -> {:ok, state}
      {:error, _reason} -> lost_channel(state)
    end
  end

  defp resize(%{stream: nil}, _cols, _rows), do: :ok

  defp resize(state, cols, rows) do
    case Streams.resize(state.stream, cols, rows) do
      :ok -> :ok
      {:error, _reason} -> {:error, :lost}
    end
  end

  defp stream_message(state, message) do
    case Streams.stream(state.stream, message) do
      :unknown -> {:ok, state}
      {events, stream} -> fold_events(events, %{state | stream: stream})
    end
  end

  defp fold_events([], state), do: arm(state)

  defp fold_events([{:data, data} | rest], state) do
    case :ssh_connection.send(state.connection, state.channel, data) do
      :ok -> fold_events(rest, state)
      {:error, _reason} -> lost_channel(state)
    end
  end

  defp fold_events([{:exit, status} | _rest], state), do: exit_channel(state, status)
  defp fold_events([:lost | _rest], state), do: lost_channel(state)

  defp arm(state) do
    case Streams.ask(state.stream) do
      :ok -> {:ok, state}
      {:error, _reason} -> lost_channel(state)
    end
  end

  defp exit_channel(state, status) do
    _ = Access.close(state.stream)
    :ssh_connection.exit_status(state.connection, state.channel, status)
    :ssh_connection.send_eof(state.connection, state.channel)
    {:stop, state.channel, %{state | stream: nil}}
  end

  defp lost_channel(state) do
    _ = Access.close(state.stream)
    :ssh_connection.exit_status(state.connection, state.channel, @lost_status)
    :ssh_connection.send_eof(state.connection, state.channel)
    {:stop, state.channel, %{state | stream: nil}}
  end

  defp close_channel(state) do
    _ = if state.stream, do: Access.close(state.stream)
    :ssh_connection.exit_status(state.connection, state.channel, @lost_status)
    :ssh_connection.send_eof(state.connection, state.channel)
    {:stop, state.channel, %{state | stream: nil}}
  end

  defp reject(connection, channel, want_reply, state) do
    :ssh_connection.reply_request(connection, want_reply, :failure, channel)
    :ssh_connection.exit_status(connection, channel, @lost_status)
    :ssh_connection.send_eof(connection, channel)
    {:stop, channel, state}
  end

  defp log_open_failure(state, reason) do
    Logger.warning(
      "SSH shell refused: biot_id=#{BiotId.to_string(state.biot_id)} reason=#{inspect(reason)}"
    )
  end

  defp user_biot(user) do
    case BiotId.parse(to_string(user)) do
      {:ok, biot_id} -> {:ok, biot_id}
      {:error, _reason} -> {:error, :invalid_user}
    end
  end

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default
end
