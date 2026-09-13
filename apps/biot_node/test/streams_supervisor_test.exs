defmodule Biot.Node.StreamsSupervisorTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Biot.Node.Control.Connection
  alias Biot.Node.Streams
  alias Biot.Node.StreamsFixture
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.ConnectionId

  setup_all do
    StreamsFixture.put_host_config("biot-streams-supervisor")
  end

  test "killing either process in the restart unit restarts both, with an empty boundary" do
    children = [
      {DynamicSupervisor, name: Streams.Children, strategy: :one_for_one},
      Streams,
      {Connection,
       [
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
    assert :applied = Streams.apply_revision(biot, cid, 1)
    assert Map.has_key?(:sys.get_state(Streams).groups.groups, biot)

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
    assert :sys.get_state(Streams).groups.groups == %{}

    connection = Process.whereis(Connection)
    assert :applied = Streams.apply_revision(biot, cid, 1)
    assert Map.has_key?(:sys.get_state(Streams).groups.groups, biot)

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

    assert :sys.get_state(Streams).groups.groups == %{}
  end

  defp fresh(name, previous) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != previous -> pid
      _other -> nil
    end
  end
end
