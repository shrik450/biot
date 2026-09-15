defmodule Biot.Node.StreamsSupervisorTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Biot.Node.Control.Connection
  alias Biot.Node.Streams
  alias Biot.Node.StreamsFixture
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.ConnectionId
  alias Biot.Protocol.Port
  alias Biot.Protocol.StreamId

  setup_all do
    StreamsFixture.put_host_config("biot-streams-supervisor")
  end

  test "killing either process in the restart unit restarts both, with an empty boundary" do
    {:ok, certificates} =
      StreamsFixture.certificates(StreamsFixture.temporary_directory("biot-supervisor-certs"))

    [node] = certificates.nodes

    # A server that is not there keeps the connection dialling, which is all this test needs of it.
    children = [
      {DynamicSupervisor, name: Streams.Children, strategy: :one_for_one},
      Streams,
      {Connection,
       [
         server_host: "127.0.0.1",
         server_port: closed_port(),
         server_fingerprint: certificates.server.fingerprint,
         registration_id: StreamsFixture.registration_id(),
         tls: [certfile: node.cert, keyfile: node.key, cacertfile: certificates.ca],
         heartbeat_interval_ms: 60_000,
         heartbeat_timeout_ms: 5_000,
         reconnect_backoff_min_ms: 50,
         reconnect_backoff_max_ms: 100
       ]}
    ]

    start_supervised!({Streams.Supervisor, children})

    boundary = Process.whereis(Streams)
    connection = Process.whereis(Connection)
    assert is_pid(boundary) and is_pid(connection)

    biot = elem(BiotId.parse(Ecto.UUID.generate()), 1)
    cid = elem(ConnectionId.parse(Ecto.UUID.generate()), 1)
    dial = dial_options(certificates)
    assert :applied = Streams.apply_revision(biot, cid, 1)
    assert known?(biot, cid, dial)

    Process.exit(connection, :kill)

    restarted_boundary =
      StreamsFixture.wait_until(
        fn -> fresh(Streams, boundary) end,
        "the boundary restarted"
      )

    _restarted_connection =
      StreamsFixture.wait_until(
        fn -> fresh(Connection, connection) end,
        "the connection restarted"
      )

    assert restarted_boundary != boundary
    refute known?(biot, cid, dial)

    connection = Process.whereis(Connection)
    assert :applied = Streams.apply_revision(biot, cid, 1)
    assert known?(biot, cid, dial)

    Process.exit(Process.whereis(Streams), :kill)

    _restarted_again =
      StreamsFixture.wait_until(
        fn -> fresh(Streams, restarted_boundary) end,
        "the boundary restarted again"
      )

    _connection_again =
      StreamsFixture.wait_until(
        fn -> fresh(Connection, connection) end,
        "the connection restarted again"
      )

    refute known?(biot, cid, dial)
  end

  # Admission at a revision the boundary never applied is refused as stale for a biot it knows and
  # as unknown for any other, so it tells the two apart without starting a stream.
  defp known?(biot, cid, dial) do
    case Streams.admit(biot, cid, 2, StreamId.generate(), {:port, elem(Port.parse(9), 1)}, dial) do
      {:error, :stale_access} -> true
      {:error, :unknown_biot} -> false
    end
  end

  defp dial_options(certificates) do
    [node] = certificates.nodes

    %{
      server_host: "127.0.0.1",
      server_port: closed_port(),
      server_fingerprint: certificates.server.fingerprint,
      registration_id: StreamsFixture.registration_id(),
      tls: [certfile: node.cert, keyfile: node.key, cacertfile: certificates.ca],
      connection_pid: self()
    }
  end

  defp closed_port do
    {:ok, listener} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listener)
    :ok = :gen_tcp.close(listener)
    port
  end

  defp fresh(name, previous) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != previous -> pid
      _other -> nil
    end
  end
end
