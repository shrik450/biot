defmodule Biot.Server.StreamsIntegrationTest do
  @moduledoc false
  use Biot.Server.DataCase, async: false

  alias Biot.Node.Host.Config, as: NodeConfig
  alias Biot.Node.Host.Paths, as: NodePaths
  alias Biot.Node.Journal.Migrator
  alias Biot.Node.Repo, as: NodeRepo
  alias Biot.Node.Streams, as: NodeStreams
  alias Biot.Node.StreamsFixture
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.NodeId
  alias Biot.Protocol.Platform
  alias Biot.Protocol.Port
  alias Biot.Protocol.RegistrationId
  alias Biot.Protocol.ShellRequest
  alias Biot.Server.Control.Listener
  alias Biot.Server.NodeConnections
  alias Biot.Server.Schema.Node
  alias Biot.Server.Streams
  alias Biot.Server.TestFixtures

  defmodule Reader do
    @moduledoc false

    def collect(stream), do: collect(stream, [])

    defp collect(stream, events) do
      receive do
        message ->
          case Streams.stream(stream, message) do
            {new_events, stream} ->
              _ = Streams.ask(stream)
              events = events ++ new_events

              if Enum.any?(new_events, &(&1 in [:closed, :lost])),
                do: events,
                else: collect(stream, events)

            :unknown ->
              collect(stream, events)
          end
      after
        10_000 -> events ++ [:timeout]
      end
    end
  end

  setup_all do
    data_root = StreamsFixture.temporary_directory("biot-server-streams")
    # Short and outside the temp root: each Biot's agent socket sits below it, and Linux caps a
    # Unix socket path at 108 bytes.
    runtime_root = BiotTest.Temp.node_root("biot-rt")
    File.mkdir_p!(runtime_root)

    host_settings = [
      data_root: data_root,
      runtime_root: runtime_root,
      uid_range_base: StreamsFixture.host_uid(),
      uid_range_count: 1,
      uid_range_limit: 65_536
    ]

    previous_settings =
      Map.new(host_settings, fn {key, _value} -> {key, Application.get_env(:biot_node, key)} end)

    Enum.each(host_settings, fn {key, value} -> Application.put_env(:biot_node, key, value) end)
    {:ok, _config} = NodeConfig.load()

    start_supervised!(NodeRepo)

    Migrator.migrate(log: false)

    start_supervised!({Task.Supervisor, name: Biot.Node.Control.RequestSupervisor})
    start_supervised!(Biot.Node.RuntimeLogs)
    start_supervised!(Biot.Node.Controllers)

    {:ok, certificates} =
      TestFixtures.certificates(
        StreamsFixture.temporary_directory("biot-server-streams-certs"),
        1
      )

    # Later modules share the node settings. A UID range left behind configures their host and
    # starts real host actions in tests that expect none.
    on_exit(fn ->
      File.rm_rf!(data_root)
      File.rm_rf!(runtime_root)
      :persistent_term.erase(NodeConfig)

      Enum.each(previous_settings, fn
        {key, nil} -> Application.delete_env(:biot_node, key)
        {key, value} -> Application.put_env(:biot_node, key, value)
      end)
    end)

    {:ok, certificates: certificates}
  end

  setup %{certificates: certificates} do
    NodeRepo.delete_all(Biot.Node.Journal.Schema.Allocation)
    previous_timeout = Application.get_env(:biot_server, :stream_open_timeout_ms)
    Application.put_env(:biot_server, :stream_open_timeout_ms, 5_000)

    listener =
      start_supervised!(
        Listener.child_spec(
          port: 0,
          tls: [
            certfile: certificates.server.cert,
            keyfile: certificates.server.key,
            cacertfile: certificates.ca
          ],
          handler_options: [
            handshake_timeout_ms: 5_000,
            heartbeat_interval_ms: 60_000,
            heartbeat_timeout_ms: 5_000
          ]
        )
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(listener)

    node_id = NodeId.generate()
    registration_id = RegistrationId.generate()
    {:ok, platform} = Platform.current()
    node_cert = hd(certificates.nodes)

    %Node{
      id: node_id,
      registration: registration_id,
      peer_identity: node_cert.fingerprint,
      status: :enabled,
      platform: platform,
      max_biots: 10
    }
    |> Repo.insert!()

    node = %{
      id: node_id,
      registration: registration_id,
      tls: [certfile: node_cert.cert, keyfile: node_cert.key, cacertfile: certificates.ca]
    }

    start_supervised!(
      {NodeStreams.Supervisor,
       [
         {DynamicSupervisor, name: NodeStreams.Children, strategy: :one_for_one},
         NodeStreams,
         {Biot.Node.Control.Connection,
          [
            server_host: "127.0.0.1",
            server_port: port,
            server_fingerprint: certificates.server.fingerprint,
            registration_id: registration_id,
            tls: node.tls,
            heartbeat_interval_ms: 60_000,
            heartbeat_timeout_ms: 5_000,
            reconnect_backoff_min_ms: 50,
            reconnect_backoff_max_ms: 100
          ]}
       ]}
    )

    connection_id =
      StreamsFixture.wait_until(
        fn ->
          case NodeConnections.current(node_id) do
            %{connection_id: connection_id, state: :ready} -> connection_id
            _other -> nil
          end
        end,
        "the node to reach ready"
      )

    on_exit(fn ->
      Application.put_env(:biot_server, :stream_open_timeout_ms, previous_timeout)
    end)

    %{node: node, connection_id: connection_id}
  end

  test "a port stream exchanges raw bytes with one read armed", context do
    biot_id = prepare_port_stream(context)
    echo_port = prepare_echo_port(biot_id)

    assert {:ok, stream} =
             Streams.open_until(
               context.node.id,
               biot_id,
               1,
               port_target(echo_port),
               open_deadline()
             )

    assert is_pid(stream.connection_pid)

    :ok = Streams.write(stream, "ping")
    assert_receive {:ssl, socket, "ping"}, 10_000
    assert Streams.stream(stream, {:ssl, socket, "ping"}) == {[{:data, "ping"}], stream}
    :ok = Streams.ask(stream)
    :ok = Streams.close(stream)
  end

  test "a shell stream reports every output byte before the exit status, then closed", context do
    biot_id = prepare_shell_stream(context)
    request = %ShellRequest{term: "xterm", cols: 80, rows: 24, command: nil}

    assert {:ok, stream} =
             Streams.open_until(context.node.id, biot_id, 1, {:shell, request}, open_deadline())

    :ok = Streams.write(stream, "echo hi\nexit\n")

    events = Reader.collect(stream)
    assert Enum.any?(events, &match?({:data, output} when byte_size(output) > 0, &1))
    assert Enum.take(events, -2) == [{:exit, 0}, :closed]
    :ok = Streams.close(stream)
  end

  test "a shell whose agent dies before an exit frame reports lost, never success", context do
    biot_id = prepare_shell_stream(context)
    request = %ShellRequest{term: "xterm", cols: 80, rows: 24, command: nil}

    assert {:ok, stream} =
             Streams.open_until(context.node.id, biot_id, 1, {:shell, request}, open_deadline())

    kill_agent(biot_id)

    events = Reader.collect(stream)
    assert :lost in events
    refute Enum.any?(events, &match?({:exit, _status}, &1))
    :ok = Streams.close(stream)
  end

  test "open_until/5 reports node_unavailable when the node has no ready link", %{} do
    node_id = NodeId.generate()
    biot_id = BiotId.generate()

    assert Streams.open_until(node_id, biot_id, 1, port_target(1), open_deadline()) ==
             {:error, :node_unavailable}
  end

  defp prepare_port_stream(context) do
    biot_id = BiotId.generate()
    assert :applied = NodeStreams.apply_revision(biot_id, context.connection_id, 1)
    biot_id
  end

  defp prepare_echo_port(biot_id) do
    socket_path =
      StreamsFixture.seed_allocation(biot_id, %{start: StreamsFixture.host_uid(), count: 1})

    _agent = StreamsFixture.start_agent(socket_path)
    StreamsFixture.start_echo_service()
  end

  defp prepare_shell_stream(context) do
    biot_id = BiotId.generate()

    socket_path =
      StreamsFixture.seed_allocation(biot_id, %{start: StreamsFixture.host_uid(), count: 1})

    _agent = StreamsFixture.start_agent(socket_path)
    assert :applied = NodeStreams.apply_revision(biot_id, context.connection_id, 1)
    biot_id
  end

  defp kill_agent(biot_id) do
    config = NodeConfig.current!()
    socket_path = Path.join(NodePaths.run(config, biot_id), "agent.sock")

    StreamsFixture.wait_until(fn -> if File.exists?(socket_path), do: :ok end, "the agent socket")

    {output, 0} = System.cmd("pgrep", ["-f", socket_path])
    output |> String.split("\n", trim: true) |> Enum.each(&System.cmd("kill", ["-KILL", &1]))
  end

  defp port_target(value), do: {:port, elem(Port.parse(value), 1)}

  defp open_deadline do
    System.monotonic_time(:millisecond) +
      Application.fetch_env!(:biot_server, :stream_open_timeout_ms)
  end
end
