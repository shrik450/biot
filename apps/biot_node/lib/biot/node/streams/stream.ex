defmodule Biot.Node.Streams.Stream do
  @moduledoc """
  One node-side stream admitted into a group.

  `Biot.Node.Streams.Children` owns its lifetime: a revision change or a lost control connection
  makes `Biot.Node.Streams` terminate it, and termination closes the sockets it holds because the
  process owns them. It never restarts.

  `init/1` does no IO, because the boundary starts it synchronously inside `Streams.admit/6`. The
  agent connection, its peer check, and the server attach all happen in `handle_continue/2` in this
  process, so a slow or hostile agent can never stall revision application or the heartbeat. Two
  linked relays then splice the agent socket and the server socket through one re-framing rule.
  """

  use GenServer

  alias Biot.Node.Host.Config
  alias Biot.Node.Host.Paths
  alias Biot.Node.Journal
  alias Biot.Node.Streams.Agent
  alias Biot.Node.Streams.Attach
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.ConnectionId
  alias Biot.Protocol.RegistrationId
  alias Biot.Protocol.ShellFrame
  alias Biot.Protocol.StreamId
  alias Biot.Protocol.StreamTarget

  @enforce_keys [:biot_id, :connection_id, :revision, :stream_id, :target, :dial_options]
  defstruct @enforce_keys ++ [agent: nil, server: nil]

  @typedoc "How this child reaches the server for its attach connection."
  @type dial_options :: %{
          server_host: String.t(),
          server_port: pos_integer(),
          server_fingerprint: String.t(),
          registration_id: RegistrationId.t(),
          tls: keyword(),
          connection_pid: pid()
        }

  @type t :: %__MODULE__{
          biot_id: BiotId.t(),
          connection_id: ConnectionId.t(),
          revision: pos_integer(),
          stream_id: StreamId.t(),
          target: StreamTarget.t(),
          dial_options: dial_options(),
          agent: :socket.socket() | nil,
          server: :ssl.sslsocket() | nil
        }

  @spec start_link(t()) :: GenServer.on_start()
  def start_link(%__MODULE__{} = stream), do: GenServer.start_link(__MODULE__, stream)

  @spec child_spec(t()) :: Supervisor.child_spec()
  def child_spec(%__MODULE__{} = stream) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [stream]},
      restart: :temporary,
      shutdown: :brutal_kill,
      type: :worker
    }
  end

  @impl true
  def init(%__MODULE__{} = stream), do: {:ok, stream, {:continue, :connect}}

  @impl true
  def handle_continue(:connect, %__MODULE__{} = stream) do
    case connect(stream) do
      {:ok, agent, server, agent_leftover, server_leftover} ->
        start_relays(stream, agent, server, agent_leftover, server_leftover)
        {:noreply, %{stream | agent: agent, server: server}}

      {:error, reason} ->
        report_failure(stream, reason)
        {:stop, {:shutdown, reason}, stream}
    end
  end

  @impl true
  def handle_info({:relay_done, reason}, %__MODULE__{} = stream) do
    {:stop, {:shutdown, reason}, stream}
  end

  defp connect(%__MODULE__{} = stream) do
    with {:ok, agent, agent_leftover} <- open_agent(stream),
         {:ok, server, server_leftover} <-
           Attach.connect(stream.dial_options, stream.connection_id, stream.stream_id) do
      {:ok, agent, server, agent_leftover, server_leftover}
    end
  end

  defp open_agent(%__MODULE__{} = stream) do
    config = Config.current!()

    case Journal.allocation(stream.biot_id) do
      nil ->
        {:error, :agent_unreachable}

      allocation ->
        path = Paths.agent_socket(config, stream.biot_id)
        Agent.connect(path, allocation.uid_range, stream.target)
    end
  end

  defp report_failure(%__MODULE__{} = stream, reason) do
    send(stream.dial_options.connection_pid, {:stream_failed, stream.stream_id, reason})
  end

  defp start_relays(%__MODULE__{} = stream, agent, server, agent_leftover, server_leftover) do
    parent = self()
    kind = StreamTarget.kind(stream.target)

    spawn_link(fn ->
      first_step(
        parent,
        receiver(server, :ssl),
        sender(agent, :socket),
        codec(kind, :to_agent),
        server_leftover
      )
    end)

    spawn_link(fn ->
      first_step(
        parent,
        receiver(agent, :socket),
        sender(server, :ssl),
        codec(kind, :to_server),
        agent_leftover
      )
    end)
  end

  # Bytes that arrived with `attached` already hold the peer's first data, so the loop handles
  # them as its first step instead of waiting for another read.
  defp first_step(parent, receiver, sender, codec, <<>>) do
    relay(parent, receiver, sender, codec, <<>>)
  end

  defp first_step(parent, receiver, sender, codec, initial) do
    continue(parent, receiver, sender, codec, <<>>, initial)
  end

  defp receiver(socket, :ssl), do: fn -> :ssl.recv(socket, 0, :infinity) end
  defp receiver(socket, :socket), do: fn -> :socket.recv(socket, 0, :infinity) end

  defp sender(socket, :ssl), do: fn data -> :ssl.send(socket, data) end
  defp sender(socket, :socket), do: fn data -> :socket.send(socket, data) end

  defp codec(:port, _direction), do: &port_codec/1
  defp codec(:shell, direction), do: &ShellFrame.reframe(&1, direction)

  defp port_codec(data), do: {:ok, data, <<>>}

  defp relay(parent, receiver, sender, codec, buffer) do
    case receiver.() do
      {:ok, data} -> continue(parent, receiver, sender, codec, buffer, data)
      {:error, reason} -> send(parent, {:relay_done, reason})
    end
  end

  defp continue(parent, receiver, sender, codec, buffer, data) do
    case codec.(buffer <> data) do
      {:ok, outgoing, rest} -> deliver(parent, receiver, sender, codec, rest, outgoing)
      {:exit, outgoing} -> deliver_exit(parent, sender, outgoing)
      {:error, reason} -> send(parent, {:relay_done, reason})
    end
  end

  defp deliver(parent, receiver, sender, codec, rest, outgoing) do
    case sender.(outgoing) do
      :ok -> relay(parent, receiver, sender, codec, rest)
      {:error, reason} -> send(parent, {:relay_done, reason})
    end
  end

  # Output is forwarded before the exit frame, and the exit frame is the last thing on the stream.
  defp deliver_exit(parent, sender, outgoing) do
    _ = sender.(outgoing)
    send(parent, {:relay_done, :exit})
  end
end
