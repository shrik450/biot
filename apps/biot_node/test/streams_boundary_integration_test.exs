defmodule Biot.Node.StreamsBoundaryIntegrationTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Biot.Node.Journal.Migrator
  alias Biot.Node.Repo
  alias Biot.Node.Streams
  alias Biot.Node.StreamsFixture
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.ConnectionId
  alias Biot.Protocol.Port
  alias Biot.Protocol.StreamId

  @stream_target {:port, elem(Port.parse(9), 1)}

  setup_all do
    :ok = StreamsFixture.put_host_config("biot-streams-boundary")

    start_supervised!(Repo)
    Migrator.migrate(log: false)

    {:ok, certificates} =
      StreamsFixture.certificates(StreamsFixture.temporary_directory("biot-streams-certs"))

    {:ok, certificates: certificates, uid: StreamsFixture.host_uid()}
  end

  setup do
    Repo.delete_all(Biot.Node.Journal.Schema.Allocation)
    :ok
  end

  defp start_boundary(limits \\ []) do
    start_supervised!(
      {DynamicSupervisor, name: Biot.Node.Streams.Children, strategy: :one_for_one}
    )

    start_supervised!({Streams, limits})
    :ok
  end

  defp biot_id, do: elem(BiotId.parse(Ecto.UUID.generate()), 1)
  defp connection_id, do: elem(ConnectionId.parse(Ecto.UUID.generate()), 1)
  defp stream_id, do: elem(StreamId.parse(Ecto.UUID.generate()), 1)

  # A stream admitted with these fails its attach at once and reports that to the test process.
  defp unreachable(certificates) do
    %{
      server_host: "127.0.0.1",
      server_port: 1,
      server_fingerprint: certificates.server.fingerprint,
      registration_id: StreamsFixture.registration_id(),
      tls: node_tls(certificates),
      connection_pid: self()
    }
  end

  defp node_tls(certificates) do
    node = hd(certificates.nodes)
    [certfile: node.cert, keyfile: node.key, cacertfile: certificates.ca]
  end

  defp live_children do
    for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(Streams.Children),
        is_pid(pid),
        do: pid
  end

  test "refuses an unknown biot, an obsolete revision, and another connection", %{
    certificates: certificates
  } do
    start_boundary()
    biot = biot_id()
    cid = connection_id()
    other = biot_id()

    assert :applied = Streams.apply_revision(biot, cid, 3)

    dial = unreachable(certificates)

    assert {:error, :stale_access} =
             Streams.admit(biot, cid, 2, stream_id(), @stream_target, dial)

    assert {:error, :stale_access} =
             Streams.admit(biot, cid, 4, stream_id(), @stream_target, dial)

    assert {:error, :stale_access} =
             Streams.admit(biot, connection_id(), 3, stream_id(), @stream_target, dial)

    assert {:error, :unknown_biot} =
             Streams.admit(other, cid, 3, stream_id(), @stream_target, dial)
  end

  # A stream counts against the limits only while it lives, so the admitted stream in each limit
  # test is real. Each test uses one, because the agent must run as the test's own UID and two
  # allocations cannot share a UID range.
  test "refuses a biot over the per-biot limit", %{certificates: certificates, uid: uid} do
    start_boundary(max_streams: 10, max_streams_per_biot: 1)
    biot = biot_id()
    cid = connection_id()

    {target, dial, _service} = live_port_stream(biot, certificates, uid)
    assert :applied = Streams.apply_revision(biot, cid, 1)
    assert :ok = Streams.admit(biot, cid, 1, stream_id(), target, dial)

    assert {:error, :too_many_streams} = Streams.admit(biot, cid, 1, stream_id(), target, dial)
  end

  test "refuses the node over the total limit", %{certificates: certificates, uid: uid} do
    start_boundary(max_streams: 1, max_streams_per_biot: 10)
    [first, second] = [biot_id(), biot_id()]
    cid = connection_id()

    {target, dial, _service} = live_port_stream(first, certificates, uid)
    for biot <- [first, second], do: assert(:applied = Streams.apply_revision(biot, cid, 1))
    assert :ok = Streams.admit(first, cid, 1, stream_id(), target, dial)

    assert {:error, :too_many_streams} =
             Streams.admit(second, cid, 1, stream_id(), @stream_target, dial)
  end

  test "a higher revision terminates the live children before apply_revision returns", %{
    certificates: certificates,
    uid: uid
  } do
    start_boundary()
    biot = biot_id()
    cid = connection_id()

    {target, dial, _service} = live_port_stream(biot, certificates, uid)
    assert :applied = Streams.apply_revision(biot, cid, 1)
    assert :ok = Streams.admit(biot, cid, 1, stream_id(), target, dial)
    [child] = live_children()

    assert :applied = Streams.apply_revision(biot, cid, 2)
    refute Process.alive?(child)
    assert live_children() == []

    assert {:error, :stale_access} = Streams.admit(biot, cid, 1, stream_id(), target, dial)
    assert :ok = Streams.admit(biot, cid, 2, stream_id(), target, unreachable(certificates))
  end

  test "repeating an applied revision re-acknowledges and a lower one is ignored", %{
    certificates: certificates,
    uid: uid
  } do
    start_boundary()
    biot = biot_id()
    cid = connection_id()

    {target, dial, _service} = live_port_stream(biot, certificates, uid)
    assert :applied = Streams.apply_revision(biot, cid, 5)
    assert :ok = Streams.admit(biot, cid, 5, stream_id(), target, dial)
    [child] = live_children()

    assert :applied = Streams.apply_revision(biot, cid, 5)
    assert Process.alive?(child)
    assert :ignored = Streams.apply_revision(biot, cid, 4)

    assert {:error, :stale_access} = Streams.admit(biot, cid, 4, stream_id(), target, dial)
    assert :ok = Streams.admit(biot, cid, 5, stream_id(), target, unreachable(certificates))
  end

  test "close_all terminates every child and empties every group", %{
    certificates: certificates,
    uid: uid
  } do
    start_boundary()
    biot = biot_id()
    cid = connection_id()

    {target, dial, _service} = live_port_stream(biot, certificates, uid)
    assert :applied = Streams.apply_revision(biot, cid, 1)
    assert :ok = Streams.admit(biot, cid, 1, stream_id(), target, dial)
    [child] = live_children()

    assert :ok = Streams.close_all()
    refute Process.alive?(child)
    assert live_children() == []
    assert {:error, :unknown_biot} = Streams.admit(biot, cid, 1, stream_id(), target, dial)
  end

  test "bytes that arrive in the same read as attached reach the agent at once", %{
    certificates: certificates,
    uid: uid
  } do
    start_boundary()
    biot = biot_id()
    cid = connection_id()
    parent = self()

    socket_path = StreamsFixture.seed_allocation(biot, %{start: uid, count: 1})
    agent = StreamsFixture.start_agent(socket_path)
    echo_port = StreamsFixture.start_echo_service()

    {port, task, listener} =
      StreamsFixture.start_attach_server(certificates, "ping", fn socket ->
        wait_for_ping(socket, parent)
      end)

    dial = %{
      server_host: "127.0.0.1",
      server_port: port,
      server_fingerprint: certificates.server.fingerprint,
      registration_id: StreamsFixture.registration_id(),
      tls: node_tls(certificates),
      connection_pid: self()
    }

    target = {:port, elem(Port.parse(echo_port), 1)}

    assert :applied = Streams.apply_revision(biot, cid, 1)
    assert :ok = Streams.admit(biot, cid, 1, stream_id(), target, dial)

    assert_receive {:server_bytes, "ping"}, 10_000

    :ssl.close(listener)
    StreamsFixture.stop_agent(agent)
    _ = Task.shutdown(task, :brutal_kill)
  end

  defp live_port_stream(biot, certificates, uid) do
    socket_path = StreamsFixture.seed_allocation(biot, %{start: uid, count: 1})
    agent = StreamsFixture.start_agent(socket_path)
    echo_port = StreamsFixture.start_echo_service()

    {port, task, listener} =
      StreamsFixture.start_attach_server(certificates, <<>>, fn socket ->
        drain(socket, self())
      end)

    dial = %{
      server_host: "127.0.0.1",
      server_port: port,
      server_fingerprint: certificates.server.fingerprint,
      registration_id: StreamsFixture.registration_id(),
      tls: node_tls(certificates),
      connection_pid: self()
    }

    target = {:port, elem(Port.parse(echo_port), 1)}
    {target, dial, %{agent: agent, task: task, listener: listener}}
  end

  defp wait_for_ping(socket, parent) do
    case :ssl.recv(socket, 0, 12_000) do
      {:ok, "ping"} ->
        send(parent, {:server_bytes, "ping"})
        :ping

      {:ok, other} ->
        send(parent, {:server_bytes, other})
        wait_for_ping(socket, parent)

      {:error, _reason} ->
        :closed
    end
  end

  defp drain(socket, parent) do
    case :ssl.recv(socket, 0, 20_000) do
      {:ok, data} ->
        send(parent, {:server_bytes, data})
        drain(socket, parent)

      {:error, _reason} ->
        :closed
    end
  end
end
