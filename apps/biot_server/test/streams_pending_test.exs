defmodule Biot.Server.StreamsPendingTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.Certificates
  alias Biot.Protocol.ConnectionId
  alias Biot.Protocol.Message
  alias Biot.Protocol.NodeId
  alias Biot.Protocol.Port
  alias Biot.Protocol.ShellFrame
  alias Biot.Protocol.StreamId
  alias Biot.Server.Id
  alias Biot.Server.NodeConnections
  alias Biot.Server.Streams
  alias Biot.Server.Streams.Pending

  defmodule FakeConnection do
    @moduledoc false
    use GenServer

    alias Biot.Server.Control.Registry, as: ControlRegistry

    def start_link(node_id, connection_id, parent) do
      GenServer.start_link(__MODULE__, {node_id, connection_id, parent})
    end

    @impl true
    def init({node_id, connection_id, parent}) do
      {:ok, _owner} = Registry.register(ControlRegistry, node_id, connection_id)
      {:ok, parent}
    end

    @impl true
    def handle_call({:open_stream, message}, _from, parent) do
      send(parent, {:opened, message})
      {:reply, :ok, parent}
    end
  end

  setup do
    previous = Application.get_env(:biot_server, :stream_open_timeout_ms)
    Application.put_env(:biot_server, :stream_open_timeout_ms, 300)
    on_exit(fn -> Application.put_env(:biot_server, :stream_open_timeout_ms, previous) end)
    :ok
  end

  setup_all do
    directory =
      Path.join(System.tmp_dir!(), "biot-streams-pending-#{System.unique_integer([:positive])}")

    {:ok, certificates} = Certificates.generate(directory, 0)

    {:ok, listener} =
      :ssl.listen(0, [
        :binary,
        {:active, false},
        {:reuseaddr, true},
        {:certfile, to_charlist(certificates.server.cert)},
        {:keyfile, to_charlist(certificates.server.key)}
      ])

    {:ok, {_address, port}} = :ssl.sockname(listener)

    on_exit(fn ->
      :ssl.close(listener)
      File.rm_rf!(directory)
    end)

    {:ok, ssl_listener: listener, ssl_port: port}
  end

  @spec connected_socket(map()) :: :ssl.sslsocket()
  defp connected_socket(context), do: elem(connected_socket_pair(context), 0)

  @spec connected_socket_pair(map()) :: {:ssl.sslsocket(), :ssl.sslsocket()}
  defp connected_socket_pair(%{ssl_listener: listener, ssl_port: port}) do
    parent = self()

    acceptor =
      spawn_link(fn ->
        {:ok, transport} = :ssl.transport_accept(listener, 5_000)
        {:ok, socket} = :ssl.handshake(transport, 5_000)
        :ok = :ssl.controlling_process(socket, parent)
        send(parent, {:accepted_ssl_socket, socket})
      end)

    {:ok, client} =
      :ssl.connect(~c"127.0.0.1", port, [verify: :verify_none, active: false], 5_000)

    socket =
      receive do
        {:accepted_ssl_socket, accepted} -> accepted
      after
        5_000 -> flunk("timed out waiting for the accepted SSL socket")
      end

    Process.unlink(acceptor)
    on_exit(fn -> :ssl.close(client) end)
    {socket, client}
  end

  defp ready_connection do
    node_id = Id.generate(NodeId)
    connection_id = Id.generate(ConnectionId)
    {:ok, _pid} = FakeConnection.start_link(node_id, connection_id, self())
    :ok = NodeConnections.put(node_id, %{connection_id: connection_id, state: :ready})
    {node_id, connection_id}
  end

  test "an open with no attach returns at the configured deadline and claims nothing" do
    {node_id, _connection_id} = ready_connection()
    biot_id = Id.generate(BiotId)
    target = {:port, elem(Port.parse(3000), 1)}

    parent = self()

    started = System.monotonic_time(:millisecond)

    caller =
      Task.async(fn ->
        result = Streams.open(node_id, biot_id, 1, target)
        send(parent, {:result, result, System.monotonic_time(:millisecond) - started})
      end)

    assert_receive {:opened, %Message.OpenStream{}}, 5_000
    assert_receive {:result, {:error, :timeout}, elapsed}, 5_000
    assert elapsed < 900
    assert :sys.get_state(Pending).entries == %{}
    Task.await(caller, 5_000)
  end

  test "an attach that arrives after the deadline finds nothing and no socket is leaked" do
    {node_id, connection_id} = ready_connection()
    biot_id = Id.generate(BiotId)
    target = {:port, elem(Port.parse(3000), 1)}

    caller = Task.async(fn -> Streams.open(node_id, biot_id, 1, target) end)
    assert_receive {:opened, %Message.OpenStream{} = message}, 5_000
    assert Task.await(caller, 5_000) == {:error, :timeout}

    assert Pending.attach(node_id, connection_id, message.stream_id, self(), make_ref()) ==
             {:error, :unknown_stream}

    refute_received {:stream_attached, _, _, _}
  end

  test "a claimed open still returns at the deadline", context do
    {node_id, connection_id} = ready_connection()
    target = {:port, elem(Port.parse(3000), 1)}

    caller = Task.async(fn -> Streams.open(node_id, Id.generate(BiotId), 1, target) end)
    assert_receive {:opened, %Message.OpenStream{} = message}, 5_000

    handler = spawn(fn -> Process.sleep(:infinity) end)
    socket = connected_socket(context)

    assert {:ok, _owner, :port} =
             Pending.attach(node_id, connection_id, message.stream_id, handler, socket)

    assert Task.await(caller, 5_000) == {:error, :timeout}
    refute Process.alive?(handler)
  end

  test "a socket moved before the handoff notice closes when the open times out", context do
    {node_id, connection_id} = ready_connection()
    target = {:port, elem(Port.parse(3000), 1)}
    parent = self()

    caller =
      Task.async(fn ->
        result = Streams.open(node_id, Id.generate(BiotId), 1, target)
        send(parent, {:open_result, result})

        receive do
          :release -> result
        end
      end)

    assert_receive {:opened, %Message.OpenStream{} = message}, 5_000
    caller_pid = caller.pid

    {socket, peer} = connected_socket_pair(context)

    handler =
      spawn(fn ->
        receive do
          {:transfer, owner} ->
            :ok = :ssl.controlling_process(socket, owner)
            send(parent, :socket_transferred)
            Process.sleep(:infinity)
        end
      end)

    :ok = :ssl.controlling_process(socket, handler)

    assert {:ok, ^caller_pid, :port} =
             Pending.attach(node_id, connection_id, message.stream_id, handler, socket)

    send(handler, {:transfer, caller.pid})
    assert_receive :socket_transferred, 5_000
    assert_receive {:open_result, {:error, :timeout}}, 5_000
    assert Process.alive?(caller.pid)
    assert :ssl.recv(peer, 0, 5_000) == {:error, :closed}
    send(caller.pid, :release)
    assert Task.await(caller, 5_000) == {:error, :timeout}
  end

  test "a claimed open returns node_unavailable when its control process dies", context do
    node_id = Id.generate(NodeId)
    connection_id = Id.generate(ConnectionId)
    {:ok, connection_pid} = FakeConnection.start_link(node_id, connection_id, self())
    :ok = NodeConnections.put(node_id, %{connection_id: connection_id, state: :ready})
    target = {:port, elem(Port.parse(3000), 1)}

    caller = Task.async(fn -> Streams.open(node_id, Id.generate(BiotId), 1, target) end)
    assert_receive {:opened, %Message.OpenStream{} = message}, 5_000

    handler = spawn(fn -> Process.sleep(:infinity) end)
    socket = connected_socket(context)

    assert {:ok, _owner, :port} =
             Pending.attach(node_id, connection_id, message.stream_id, handler, socket)

    Process.unlink(connection_pid)
    Process.exit(connection_pid, :kill)

    assert Task.await(caller, 5_000) == {:error, :node_unavailable}
    refute Process.alive?(handler)
  end

  test "a killed control process fails its opens and refuses its attach" do
    node_id = Id.generate(NodeId)
    connection_id = Id.generate(ConnectionId)
    {:ok, connection_pid} = FakeConnection.start_link(node_id, connection_id, self())
    :ok = NodeConnections.put(node_id, %{connection_id: connection_id, state: :ready})
    target = {:port, elem(Port.parse(3000), 1)}

    caller = Task.async(fn -> Streams.open(node_id, Id.generate(BiotId), 1, target) end)
    assert_receive {:opened, %Message.OpenStream{} = message}, 5_000

    Process.unlink(connection_pid)
    Process.exit(connection_pid, :kill)

    assert Task.await(caller, 5_000) == {:error, :node_unavailable}

    assert Pending.attach(node_id, connection_id, message.stream_id, self(), make_ref()) ==
             {:error, :unknown_stream}
  end

  test "stream/2 reports unknown for anything that is not this stream's transport" do
    stream = %Streams.Stream{
      id: Id.generate(StreamId),
      kind: :port,
      socket: make_ref(),
      connection_pid: self()
    }

    assert Streams.stream(stream, {:other, :message}) == :unknown
    assert Streams.stream(stream, {:ssl, make_ref(), "x"}) == :unknown
    assert Streams.stream(stream, {:tcp, :socket, "x"}) == :unknown
    assert Streams.stream(stream, :random) == :unknown
  end

  test "a port stream reports data and closed, and a shell stream distinguishes closed from lost" do
    socket = make_ref()

    port = %Streams.Stream{
      id: Id.generate(StreamId),
      kind: :port,
      socket: socket,
      connection_pid: self()
    }

    assert Streams.stream(port, {:ssl, socket, "bytes"}) == {[{:data, "bytes"}], port}
    assert {[:closed], _port} = Streams.stream(port, {:ssl_closed, socket})

    shell = %Streams.Stream{
      id: Id.generate(StreamId),
      kind: :shell,
      socket: socket,
      connection_pid: self()
    }

    assert {[:lost], _shell} = Streams.stream(shell, {:ssl_closed, socket})

    {:ok, exit_frame} = ShellFrame.encode({:exit, 7})
    {[{:exit, 7}], ended} = Streams.stream(shell, {:ssl, socket, IO.iodata_to_binary(exit_frame)})
    assert {[:closed], _ended} = Streams.stream(ended, {:ssl_closed, socket})
  end

  test "attach rejects a wrong node, an old connection, and an unknown stream, and claims a current one" do
    node_id = Id.generate(NodeId)
    connection_id = Id.generate(ConnectionId)
    id = Id.generate(StreamId)
    handler = self()
    connection_pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(connection_pid, :kill) end)
    pending_pid = Process.whereis(Pending)
    monitors_before = pending_monitors(pending_pid)

    :ok = Pending.register(id, node_id, connection_id, connection_pid, :port, self())
    monitors_after_register = pending_monitors(pending_pid)
    assert MapSet.size(monitors_after_register) == MapSet.size(monitors_before) + 2

    assert Pending.attach(Id.generate(NodeId), connection_id, id, handler, make_ref()) ==
             {:error, :unknown_stream}

    assert Pending.attach(node_id, Id.generate(ConnectionId), id, handler, make_ref()) ==
             {:error, :unknown_stream}

    assert Pending.attach(node_id, connection_id, Id.generate(StreamId), handler, make_ref()) ==
             {:error, :unknown_stream}

    :ok = NodeConnections.put(node_id, %{connection_id: connection_id, state: :ready})
    socket = make_ref()
    assert Pending.attach(node_id, connection_id, id, handler, socket) == {:ok, self(), :port}
    assert_received {:stream_claimed, ^id, ^handler, ^socket}
    assert pending_monitors(pending_pid) == monitors_before

    assert Pending.attach(node_id, connection_id, id, handler, make_ref()) ==
             {:error, :unknown_stream}
  end

  test "control loss fails every open for that connection" do
    {node_id, connection_id} = ready_connection()
    other_node_id = Id.generate(NodeId)
    other_connection_id = Id.generate(ConnectionId)
    {:ok, _pid} = FakeConnection.start_link(other_node_id, other_connection_id, self())
    :ok = NodeConnections.put(other_node_id, %{connection_id: other_connection_id, state: :ready})

    target = {:port, elem(Port.parse(3000), 1)}

    first =
      Task.async(fn -> Streams.open(node_id, Id.generate(BiotId), 1, target) end)

    second =
      Task.async(fn ->
        Streams.open(other_node_id, Id.generate(BiotId), 1, target)
      end)

    assert_receive {:opened, %Message.OpenStream{}}, 5_000
    assert_receive {:opened, %Message.OpenStream{}}, 5_000

    assert :ok = Pending.control_lost(connection_id)

    assert Task.await(first, 5_000) == {:error, :node_unavailable}
    assert Task.await(second, 5_000) == {:error, :timeout}
  end

  @spec pending_monitors(pid()) :: MapSet.t()
  defp pending_monitors(pending_pid) do
    {:monitors, monitors} = Process.info(pending_pid, :monitors)
    MapSet.new(monitors)
  end
end
