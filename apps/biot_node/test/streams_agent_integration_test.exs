defmodule Biot.Node.StreamsAgentIntegrationTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Biot.Node.Journal.Migrator
  alias Biot.Node.Repo
  alias Biot.Node.Streams
  alias Biot.Node.Streams.Agent
  alias Biot.Node.StreamsFixture
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.ConnectionId
  alias Biot.Protocol.Port
  alias Biot.Protocol.StreamId

  setup_all do
    :ok = StreamsFixture.put_host_config("biot-streams-agent")

    start_supervised!(Repo)

    Migrator.migrate(log: false)

    {:ok, uid: StreamsFixture.host_uid()}
  end

  setup do
    Repo.delete_all(Biot.Node.Journal.Schema.Allocation)
    :ok
  end

  defp port_target, do: {:port, elem(Port.parse(3000), 1)}
  defp out_of_range, do: %{start: 50_000, count: 10}

  test "an in-range peer receives the exact target line", %{uid: uid} do
    directory = StreamsFixture.temporary_directory("biot-agent")
    path = Path.join(directory, "agent.sock")

    StreamsFixture.start_fake_agent(path, ~s({"ok":true}), self())
    assert_receive {:listening, _pid}, 5_000

    assert {:ok, socket, ""} = Agent.connect(path, %{start: uid, count: 1}, port_target())
    assert_receive {:request, line}, 5_000
    assert Jason.decode!(line) == %{"target" => "port", "port" => 3000}
    _ = :socket.close(socket)
  end

  test "returns stream bytes that arrived with the reply in one write", %{uid: uid} do
    directory = StreamsFixture.temporary_directory("biot-agent")
    path = Path.join(directory, "agent.sock")

    StreamsFixture.start_fake_agent(path, ~s({"ok":true}), self(), "banner")
    assert_receive {:listening, _pid}, 5_000

    assert {:ok, socket, "banner"} = Agent.connect(path, %{start: uid, count: 1}, port_target())
    assert_receive {:request, _line}, 5_000
    _ = :socket.close(socket)
  end

  test "a peer outside the range gets no target bytes and is refused", %{uid: _uid} do
    directory = StreamsFixture.temporary_directory("biot-agent")
    path = Path.join(directory, "agent.sock")

    StreamsFixture.start_fake_agent(path, ~s({"ok":true}), self())
    assert_receive {:listening, _pid}, 5_000

    assert Agent.connect(path, out_of_range(), port_target()) == {:error, :agent_unreachable}
    assert_receive {:no_request, reason}, 5_000
    assert reason in [:closed, :timeout]
  end

  test "the agent's rejections map to the model's stream failures", %{uid: uid} do
    for {reply, expected} <- [
          {~s({"ok":false,"error":"connection_refused"}), :port_not_listening},
          {~s({"ok":false,"error":"invalid_request"}), :agent_unreachable},
          {"not json", :agent_unreachable},
          {~s({"ok":false,"error":"other"}), :agent_unreachable}
        ] do
      directory = StreamsFixture.temporary_directory("biot-agent")
      path = Path.join(directory, "agent.sock")
      StreamsFixture.start_fake_agent(path, reply, self())
      assert_receive {:listening, _pid}, 5_000

      assert Agent.connect(path, %{start: uid, count: 1}, port_target()) == {:error, expected}
      assert_receive {:request, _line}, 5_000
    end
  end

  test "the pure UID range keeps exactly the mapped range", %{} do
    credentials = fn uid -> <<0::32, uid::native-32, 0::native-32>> end

    assert Agent.peer_in_range?(credentials.(1000), %{start: 1000, count: 1})
    assert Agent.peer_in_range?(credentials.(1500), %{start: 1000, count: 501})
    refute Agent.peer_in_range?(credentials.(999), %{start: 1000, count: 1})
    refute Agent.peer_in_range?(credentials.(1001), %{start: 1000, count: 1})
    refute Agent.peer_in_range?(<<1, 2, 3>>, %{start: 1000, count: 1})
  end

  test "the stream child sends no target and reports agent_unreachable for an out-of-range peer",
       %{} do
    start_supervised!(
      {DynamicSupervisor, name: Biot.Node.Streams.Children, strategy: :one_for_one}
    )

    start_supervised!({Streams, [max_streams: 4, max_streams_per_biot: 2]})

    biot = elem(BiotId.parse(Ecto.UUID.generate()), 1)
    cid = elem(ConnectionId.parse(Ecto.UUID.generate()), 1)
    id = elem(StreamId.parse(Ecto.UUID.generate()), 1)

    socket_path = StreamsFixture.seed_allocation(biot, out_of_range())
    StreamsFixture.start_fake_agent(socket_path, ~s({"ok":true}), self())
    assert_receive {:listening, _pid}, 5_000

    dial = %{
      server_host: "127.0.0.1",
      server_port: 1,
      server_fingerprint: String.duplicate("a", 64),
      registration_id: StreamsFixture.registration_id(),
      tls: [],
      connection_pid: self()
    }

    assert :applied = Streams.apply_revision(biot, cid, 1)
    assert :ok = Streams.admit(biot, cid, 1, id, port_target(), dial)

    assert_receive {:stream_failed, ^id, :agent_unreachable}, 5_000
    assert_receive {:no_request, reason}, 5_000
    assert reason in [:closed, :timeout]
  end
end
