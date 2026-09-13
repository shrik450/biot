defmodule Biot.Node.Streams.Attach do
  @moduledoc """
  Dials the server for one node stream and completes the attach handshake.

  The stream connection uses the control listener and the same mutual TLS as the control link
  through `Biot.Node.Control.Dial`. Its first frame is `attach`, not `hello`, and it carries the
  control connection id so the server can only admit it into the group that connection applied.
  """

  alias Biot.Node.Control.Dial
  alias Biot.Node.Deadline
  alias Biot.Protocol.ConnectionId
  alias Biot.Protocol.Frame
  alias Biot.Protocol.Message
  alias Biot.Protocol.StreamId
  alias Biot.Protocol.Wire

  @timeout_ms 5_000

  @spec connect(Dial.dial_options(), ConnectionId.t(), StreamId.t()) ::
          {:ok, :ssl.sslsocket(), binary()} | {:error, :agent_unreachable | :stale_access}
  def connect(dial, %ConnectionId{} = connection_id, %StreamId{} = stream_id) do
    case Dial.connect(dial, @timeout_ms) do
      {:ok, socket} -> run(socket, dial.registration_id, connection_id, stream_id)
      {:error, _reason} -> {:error, :agent_unreachable}
    end
  end

  defp run(socket, registration_id, connection_id, stream_id) do
    with :ok <- send_attach(socket, registration_id, connection_id, stream_id),
         {:ok, leftover} <- await_attached(socket) do
      {:ok, socket, leftover}
    else
      {:error, reason} -> close(socket, reason)
    end
  end

  defp send_attach(socket, registration_id, connection_id, stream_id) do
    message = %Message.Attach{
      registration_id: registration_id,
      connection_id: connection_id,
      stream_id: stream_id
    }

    with {:ok, encoded} <- Wire.encode(message, :handshake) do
      :ssl.send(socket, Frame.encode(encoded))
    end
  end

  defp await_attached(socket) do
    deadline = Deadline.from_timeout(@timeout_ms)
    max_frame_bytes = Application.fetch_env!(:biot_node, :max_frame_bytes)
    await_attached(socket, <<>>, deadline, max_frame_bytes)
  end

  # Exactly one control frame, so any bytes after it are the start of the stream and are returned
  # untouched rather than re-decoded as frames.
  defp await_attached(socket, buffer, deadline, max_frame_bytes) do
    case Frame.take(buffer, max_frame_bytes) do
      {:ok, frame, leftover} -> decode_attach_reply(frame, leftover)
      :more -> read_more_attached(socket, buffer, deadline, max_frame_bytes)
      {:error, _reason} -> {:error, :agent_unreachable}
    end
  end

  defp read_more_attached(socket, buffer, deadline, max_frame_bytes) do
    case Deadline.remaining(deadline) do
      :timeout -> {:error, :agent_unreachable}
      time -> recv_attached(socket, buffer, deadline, max_frame_bytes, time)
    end
  end

  defp recv_attached(socket, buffer, deadline, max_frame_bytes, time) do
    case :ssl.recv(socket, 0, time) do
      {:ok, data} -> await_attached(socket, buffer <> data, deadline, max_frame_bytes)
      {:error, _reason} -> {:error, :agent_unreachable}
    end
  end

  defp decode_attach_reply(frame, leftover) do
    case Wire.decode(frame, :handshake) do
      {:ok, %Message.Attached{}} -> {:ok, leftover}
      {:ok, %Message.Reject{}} -> {:error, :stale_access}
      {:ok, _other} -> {:error, :agent_unreachable}
      {:error, _reason} -> {:error, :agent_unreachable}
    end
  end

  defp close(socket, reason) do
    _ = :ssl.close(socket)
    {:error, reason}
  end
end
