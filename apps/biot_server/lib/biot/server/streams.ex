defmodule Biot.Server.Streams do
  @moduledoc """
  The server caller's stream API.

  `open/4` asks the node's ready control connection to open a stream and waits for the attach. The
  attach handler moves the raw SSL socket to this caller with `:ssl.controlling_process/2`, and
  from then on the caller owns it.

  `stream/2` decodes `:ssl` messages into typed events and returns `:unknown` for anything else, so
  a WebSocket or SSH process can pass every message it receives without matching on the transport.
  `ask/1` re-arms one read; reading one chunk per `ask/1` is the backpressure, because the node
  cannot send the next chunk until the owner has processed this one.
  """

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.Message
  alias Biot.Protocol.NodeId
  alias Biot.Protocol.ShellFrame
  alias Biot.Protocol.StreamFailure
  alias Biot.Protocol.StreamId
  alias Biot.Protocol.StreamTarget
  alias Biot.Server.Control.Connection, as: ControlConnection
  alias Biot.Server.Id
  alias Biot.Server.NodeConnections
  alias Biot.Server.Streams.Pending

  @shell_payload ShellFrame.max_payload()

  @type open_error :: StreamFailure.t() | :timeout | :node_unavailable

  defmodule Stream do
    @moduledoc "One attached stream, owned by the process that called `open/4`."
    @enforce_keys [:id, :kind, :socket, :connection_pid]
    defstruct [:id, :kind, :socket, :connection_pid, buffer: <<>>, exited: false]

    @type t :: %__MODULE__{
            id: StreamId.t(),
            kind: :port | :shell,
            socket: :ssl.sslsocket(),
            connection_pid: pid(),
            buffer: binary(),
            exited: boolean()
          }
  end

  @type event :: {:data, binary()} | {:exit, 0..255} | :closed | :lost

  @spec open(NodeId.t(), BiotId.t(), pos_integer(), StreamTarget.t()) ::
          {:ok, Stream.t()} | {:error, open_error()}
  def open(%NodeId{} = node_id, %BiotId{} = biot_id, access_revision, target) do
    with {:ok, connection_pid, connection_id} <- ready_connection(node_id) do
      deadline = System.monotonic_time(:millisecond) + timeout_ms()
      id = Id.generate(StreamId)
      kind = StreamTarget.kind(target)
      :ok = Pending.register(id, node_id, connection_id, connection_pid, kind, self())

      message = %Message.OpenStream{
        connection_id: connection_id,
        access_revision: access_revision,
        stream_id: id,
        biot_id: biot_id,
        target: target
      }

      case ControlConnection.open_stream(connection_pid, message, remaining(deadline)) do
        :ok ->
          await(id, connection_pid, deadline)

        {:error, :node_unavailable} ->
          deadline(id, connection_pid, deadline, :node_unavailable)
      end
    end
  end

  @doc """
  Turns one message into typed events for this stream.

  A shell stream decodes its frames here, so an owner only ever sees `{:data, bytes}`,
  `{:exit, status}`, `:closed`, or `:lost`. Anything that is not this stream's transport message
  returns `:unknown`. A frame that does not decode closes the socket and reports `:lost`.
  """
  @spec stream(Stream.t(), term()) :: {[event()], Stream.t()} | :unknown
  def stream(%Stream{kind: :port, socket: socket} = stream, {:ssl, socket, data}) do
    {[{:data, data}], stream}
  end

  def stream(%Stream{kind: :shell, socket: socket} = stream, {:ssl, socket, data}) do
    decode_shell(stream, data)
  end

  def stream(%Stream{kind: :port, socket: socket} = stream, {:ssl_closed, socket}),
    do: {[:closed], stream}

  def stream(%Stream{kind: :shell, socket: socket} = stream, {:ssl_closed, socket}),
    do: {[closing_event(stream)], stream}

  def stream(%Stream{kind: :port, socket: socket} = stream, {:ssl_error, socket, _reason}),
    do: {[:closed], stream}

  def stream(%Stream{kind: :shell, socket: socket} = stream, {:ssl_error, socket, _reason}),
    do: {[closing_event(stream)], stream}

  def stream(%Stream{}, _message), do: :unknown

  # A shell that closes after an exit frame ended normally; one that closes before it lost its
  # session, which is never success.
  defp closing_event(%Stream{exited: true}), do: :closed
  defp closing_event(%Stream{exited: false}), do: :lost

  @doc "Re-arms one read, letting the peer send the next chunk."
  @spec ask(Stream.t()) :: :ok | {:error, term()}
  def ask(%Stream{socket: socket}), do: :ssl.setopts(socket, active: :once)

  @spec write(Stream.t(), iodata()) :: :ok | {:error, term()}
  def write(%Stream{kind: :port, socket: socket}, data), do: :ssl.send(socket, data)
  def write(%Stream{kind: :shell, socket: socket}, data), do: write_shell_data(socket, data)

  @spec resize(Stream.t(), pos_integer(), pos_integer()) :: :ok | {:error, term()}
  def resize(%Stream{kind: :shell, socket: socket}, cols, rows) do
    with {:ok, frame} <- ShellFrame.encode({:resize, cols, rows}) do
      :ssl.send(socket, frame)
    end
  end

  @spec close(Stream.t()) :: :ok
  def close(%Stream{socket: socket}), do: :ssl.close(socket)

  defp ready_connection(node_id) do
    case NodeConnections.ready_connection(node_id) do
      {:ok, pid, connection_id} -> {:ok, pid, connection_id}
      {:error, :temporarily_unavailable} -> {:error, :node_unavailable}
    end
  end

  defp timeout_ms, do: Application.fetch_env!(:biot_server, :stream_open_timeout_ms)

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp await(id, connection_pid, deadline) do
    receive do
      {:stream_failed, ^id, reason} ->
        {:error, reason}

      {:stream_claimed, ^id, handler, socket} ->
        await_handoff(id, handler, connection_pid, socket, deadline)
    after
      remaining(deadline) -> deadline(id, connection_pid, deadline)
    end
  end

  # Claim and abandon both run in Pending, so exactly one wins. If abandon won, no handler can
  # ever send this stream's socket. If claim won, its message is already in this mailbox.
  defp deadline(id, connection_pid, open_deadline, abandoned_reason \\ :timeout) do
    case Pending.abandon(id) do
      :abandoned -> {:error, abandoned_reason}
      :gone -> drain(id, connection_pid, open_deadline)
    end
  end

  defp drain(id, connection_pid, open_deadline) do
    receive do
      {:stream_failed, ^id, reason} ->
        {:error, reason}

      {:stream_claimed, ^id, handler, socket} ->
        await_handoff(id, handler, connection_pid, socket, open_deadline)
    after
      0 -> {:error, :timeout}
    end
  end

  # The claim carries the socket, so a killed handler cannot move it to the caller without the
  # caller knowing which socket it is. The handler stays alive after it hands the socket over, so
  # its messages arrive in the order it sent them: `stream_attached` if it transferred, `:DOWN`
  # first only if it failed. The deadline and the admitting control connection still bound the wait.
  defp await_handoff(id, handler, connection_pid, socket, open_deadline) do
    handler_monitor = Process.monitor(handler)
    connection_monitor = Process.monitor(connection_pid)

    receive do
      {:stream_attached, ^id, kind, _socket} ->
        Process.demonitor(handler_monitor, [:flush])
        Process.demonitor(connection_monitor, [:flush])
        {:ok, %Stream{id: id, kind: kind, socket: socket, connection_pid: connection_pid}}

      {:DOWN, ^handler_monitor, :process, ^handler, _reason} ->
        Process.demonitor(connection_monitor, [:flush])
        close_claimed(socket)
        {:error, :node_unavailable}

      {:DOWN, ^connection_monitor, :process, ^connection_pid, _reason} ->
        abandon_handoff(handler, socket, :node_unavailable)
    after
      remaining(open_deadline) ->
        Process.demonitor(connection_monitor, [:flush])
        abandon_handoff(handler, socket, :timeout)
    end
  end

  defp abandon_handoff(handler, socket, reason) do
    Process.exit(handler, :kill)
    await_handler_down(handler)
    close_claimed(socket)
    {:error, reason}
  end

  defp await_handler_down(handler) do
    receive do
      {:DOWN, _reference, :process, ^handler, _reason} -> :ok
    after
      5_000 -> :ok
    end
  end

  # The handler's death closes the socket only if it still owned it; if the transfer happened, the
  # caller does, so this close is what ends it. An already-closed socket returns an ignored error.
  defp close_claimed(socket), do: _ = :ssl.close(socket)

  defp decode_shell(%Stream{buffer: buffer} = stream, data) do
    case ShellFrame.decode(buffer <> data, :to_server) do
      {:ok, frames, rest} ->
        exited = stream.exited or Enum.any?(frames, &match?({:exit, _status}, &1))
        {frames, %{stream | buffer: rest, exited: exited}}

      {:error, _reason} ->
        _ = :ssl.close(stream.socket)
        {[:lost], %{stream | buffer: <<>>, exited: true}}
    end
  end

  defp write_shell_data(socket, data) do
    data
    |> IO.iodata_to_binary()
    |> chunks()
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      with {:ok, frame} <- ShellFrame.encode({:data, chunk}),
           :ok <- :ssl.send(socket, frame) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp chunks(<<chunk::binary-size(@shell_payload), rest::binary>>), do: [chunk | chunks(rest)]
  defp chunks(rest), do: [rest]
end
