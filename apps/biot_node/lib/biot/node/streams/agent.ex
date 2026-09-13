defmodule Biot.Node.Streams.Agent do
  @moduledoc """
  Opens and verifies one biot's agent connection.

  The socket path proves nothing on its own: a collaborator inside the biot can replace it with a
  symlink to another biot's socket or to an unrelated host socket. So before any target byte is
  written, this reads the connected peer's kernel credentials and requires its host UID to lie in
  the allocation's mapped range. A mismatch closes the socket, and the agent never learns what was
  asked of it.

  The request line and the reply are bounded by the agent protocol. The reply is parsed into the
  shared `AgentReply` value, so an invalid reply is a stream failure rather than a crash.
  """

  alias Biot.Node.Deadline
  alias Biot.Protocol.AgentReply
  alias Biot.Protocol.Limits
  alias Biot.Protocol.StreamFailure
  alias Biot.Protocol.StreamTarget

  # SO_PEERCRED is option 17 at the SOL_SOCKET level on Linux for both x86_64 and aarch64, and
  # struct ucred is three native 32-bit fields.
  @so_peercred 17
  @ucred_bytes 12
  @reply_timeout_ms 5_000
  @max_agent_line_bytes Limits.max_agent_line_bytes()

  @type uid_range :: %{start: non_neg_integer(), count: pos_integer()}

  @spec connect(Path.t(), uid_range(), StreamTarget.t()) ::
          {:ok, :socket.socket(), binary()} | {:error, StreamFailure.t()}
  def connect(path, uid_range, target) do
    case open(path) do
      {:ok, socket} -> verify_and_send(socket, uid_range, target)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Whether one connected peer's kernel credentials name a UID in the allocation's range."
  @spec peer_in_range?(binary(), uid_range()) :: boolean()
  def peer_in_range?(
        <<_pid::native-32, uid::native-32, _gid::native-32>>,
        %{start: start, count: count}
      ) do
    uid >= start and uid < start + count
  end

  def peer_in_range?(_credentials, _uid_range), do: false

  defp verify_and_send(socket, uid_range, target) do
    with :ok <- verify_peer(socket, uid_range),
         :ok <- send_target(socket, target),
         {:ok, reply, leftover} <- read_reply(socket),
         :ok <- accept_reply(reply) do
      {:ok, socket, leftover}
    else
      {:error, reason} -> close(socket, reason)
    end
  end

  defp open(path) do
    case :socket.open(:local, :stream, %{}) do
      {:ok, socket} -> connect_socket(socket, path)
      {:error, _reason} -> {:error, :agent_unreachable}
    end
  end

  defp connect_socket(socket, path) do
    case :socket.connect(socket, %{family: :local, path: path}) do
      :ok -> {:ok, socket}
      {:error, _reason} -> close(socket, :agent_unreachable)
    end
  end

  defp verify_peer(socket, uid_range) do
    case :socket.getopt_native(socket, {:socket, @so_peercred}, @ucred_bytes) do
      {:ok, credentials} ->
        if peer_in_range?(credentials, uid_range), do: :ok, else: {:error, :agent_unreachable}

      {:error, _reason} ->
        {:error, :agent_unreachable}
    end
  end

  defp send_target(socket, target) do
    case :socket.send(socket, [Jason.encode!(StreamTarget.encode(target)), "\n"]) do
      :ok -> :ok
      {:error, _reason} -> {:error, :agent_unreachable}
    end
  end

  defp read_reply(socket) do
    deadline = Deadline.from_timeout(@reply_timeout_ms)
    read_reply(socket, <<>>, deadline)
  end

  # The bound is the reply line, newline included. Bytes after the newline are stream data that
  # arrived in the same read, and they are returned untouched.
  defp read_reply(socket, buffer, deadline) do
    case :binary.match(buffer, "\n") do
      {index, 1} -> reply_at(buffer, index)
      :nomatch when byte_size(buffer) > @max_agent_line_bytes -> {:error, :agent_unreachable}
      :nomatch -> read_more_reply(socket, buffer, deadline)
    end
  end

  defp reply_at(buffer, index) do
    if index + 1 <= @max_agent_line_bytes do
      line = binary_part(buffer, 0, index)
      leftover = binary_part(buffer, index + 1, byte_size(buffer) - index - 1)

      with {:ok, reply} <- parse_reply(line) do
        {:ok, reply, leftover}
      end
    else
      {:error, :agent_unreachable}
    end
  end

  defp read_more_reply(socket, buffer, deadline) do
    case Deadline.remaining(deadline) do
      :timeout -> {:error, :agent_unreachable}
      time -> recv_reply(socket, buffer, deadline, time)
    end
  end

  defp recv_reply(socket, buffer, deadline, time) do
    case :socket.recv(socket, 0, time) do
      {:ok, data} -> read_reply(socket, buffer <> data, deadline)
      {:error, _reason} -> {:error, :agent_unreachable}
    end
  end

  defp parse_reply(line) do
    with {:ok, value} <- Jason.decode(line),
         {:ok, reply} <- AgentReply.parse(value) do
      {:ok, reply}
    else
      _error -> {:error, :agent_unreachable}
    end
  end

  defp accept_reply(:ok), do: :ok
  defp accept_reply({:error, :connection_refused}), do: {:error, :port_not_listening}
  defp accept_reply({:error, :invalid_request}), do: {:error, :agent_unreachable}

  defp close(socket, reason) do
    _ = :socket.close(socket)
    {:error, reason}
  end
end
