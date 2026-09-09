defmodule Biot.Server.ControlProtocolIntegrationTest do
  use Biot.Server.DataCase, async: false

  import ExUnit.CaptureLog

  alias Biot.Node.Control, as: NodeControl
  alias Biot.Node.Control.Connection, as: NodeConnection
  alias Biot.Node.Diagnostics, as: NodeDiagnostics
  alias Biot.Node.Journal, as: NodeJournal
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.Certificates
  alias Biot.Protocol.Frame
  alias Biot.Protocol.Message
  alias Biot.Protocol.OrphanedAllocation
  alias Biot.Protocol.Platform
  alias Biot.Protocol.PrivateDiagnosticId
  alias Biot.Protocol.RegistrationId
  alias Biot.Protocol.Wire
  alias Biot.Server.Biots
  alias Biot.Server.Biots.Accepted
  alias Biot.Server.Biots.Unchanged
  alias Biot.Server.Control.Listener
  alias Biot.Server.Diagnostics, as: ServerDiagnostics
  alias Biot.Server.NodeConnections
  alias Biot.Server.Nodes
  alias Biot.Server.Nodes.Registration
  alias Biot.Server.Repo
  alias Biot.Server.Schema.AccessObservation
  alias Biot.Server.Schema.Biot, as: BiotRow
  alias Biot.Server.Schema.Environment
  alias Biot.Server.Schema.Node
  alias Biot.Server.Schema.NodeObservation
  alias Biot.Server.Schema.Observation
  alias Biot.Server.Schema.Operation
  alias Biot.Server.TestFixtures

  @eventually_timeout 2_000
  @receive_timeout 1_000

  setup_all do
    directory =
      Path.join(
        System.tmp_dir!(),
        "biot-control-integration-#{System.unique_integer([:positive])}"
      )

    {:ok, certificates} = Certificates.generate(directory, 5)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{certificates: certificates}
  end

  setup do
    previous_timeout = Application.get_env(:biot_server, :diagnostic_timeout_ms)
    previous_max_bytes = Application.get_env(:biot_server, :diagnostic_max_bytes)
    previous_registrations = Application.get_env(:biot_server, :node_registrations)
    Application.put_env(:biot_server, :diagnostic_timeout_ms, 100)
    Application.put_env(:biot_server, :diagnostic_max_bytes, 8)

    on_exit(fn ->
      restore_env(:diagnostic_timeout_ms, previous_timeout)
      restore_env(:diagnostic_max_bytes, previous_max_bytes)
      restore_env(:node_registrations, previous_registrations)
    end)
  end

  test "an enrolled node reaches ready and receives the complete synchronize set", context do
    listener = start_listener(context.certificates)
    owner = TestFixtures.principal(1)
    actor = TestFixtures.actor(owner)
    node = node_for_certificate(1, context.certificates, 0)
    biot_id = TestFixtures.id(BiotId, 8_001)

    assert {:ok, %Accepted{}} =
             Biots.create(
               actor,
               biot_id,
               TestFixtures.create_command(name: "full-path", node_id: node.id)
             )

    {socket, connected, specs} = ready_peer(listener.port, context.certificates, node, 0)

    assert NodeConnections.current(node.id) == %{
             connection_id: connected.connection_id,
             state: :ready
           }

    assert [%{execution: %{biot_id: ^biot_id}} = spec] = specs
    assert spec.access_revision == Repo.get!(BiotRow, biot_id).access_revision
    :ssl.close(socket)
  end

  test "handshake rejection hides registration membership and permits disabled nodes", context do
    listener = start_listener(context.certificates)
    enabled = node_for_certificate(1, context.certificates, 0)
    retired = node_for_certificate(2, context.certificates, 2, status: :retired)
    disabled = node_for_certificate(3, context.certificates, 3, status: :disabled)

    unsupported = connect(listener.port, context.certificates, 0)
    send_hello(unsupported, enabled.registration, [99])

    assert %Message.Reject{reason: :unsupported_protocol_version} =
             await_message(unsupported, :handshake, Message.Reject)

    assert_closed(unsupported)
    assert NodeConnections.current(enabled.id) == nil

    mismatch_log =
      capture_log(fn ->
        mismatch = connect(listener.port, context.certificates, 1)
        send_hello(mismatch, enabled.registration, [1])

        assert %Message.Reject{reason: :registration_rejected} =
                 await_message(mismatch, :handshake, Message.Reject)

        assert_closed(mismatch)
      end)

    assert mismatch_log =~ "peer_identity_mismatch"

    unknown_log =
      capture_log(fn ->
        unknown = connect(listener.port, context.certificates, 1)
        send_hello(unknown, TestFixtures.id(RegistrationId, 99_999), [1])

        assert %Message.Reject{reason: :registration_rejected} =
                 await_message(unknown, :handshake, Message.Reject)

        assert_closed(unknown)
      end)

    assert unknown_log =~ "unknown_registration"

    retired_socket = connect(listener.port, context.certificates, 2)
    send_hello(retired_socket, retired.registration, [1])

    assert %Message.Reject{reason: :registration_retired} =
             await_message(retired_socket, :handshake, Message.Reject)

    assert_closed(retired_socket)

    {disabled_socket, _connected, _synchronize} =
      ready_peer(listener.port, context.certificates, disabled, 3)

    assert %{state: :ready} = NodeConnections.current(disabled.id)
    :ssl.close(disabled_socket)
  end

  test "invalid pre-handshake input and an idle peer close without synchronization", context do
    listener =
      start_listener(context.certificates,
        handshake_timeout_ms: 40,
        max_frame_bytes: 1_000
      )

    node = node_for_certificate(1, context.certificates, 0)
    biot_id = TestFixtures.id(BiotId, 8_002)
    report = TestFixtures.execution_report()

    observation = connect(listener.port, context.certificates, 0)

    send_message(
      observation,
      %Message.Observation{biot_id: biot_id, execution_report: report},
      1
    )

    assert_closed(observation)
    assert NodeConnections.current(node.id) == nil

    idle = connect(listener.port, context.certificates, 0)
    assert_closed(idle)

    oversized = connect(listener.port, context.certificates, 0)
    assert :ok = :ssl.send(oversized, <<1_001::unsigned-big-32>>)
    assert_closed(oversized)
  end

  test "the newest connection replaces the old one without losing the current entry", context do
    listener = start_listener(context.certificates)
    node = node_for_certificate(1, context.certificates, 0)

    {first_socket, first, _synchronize} =
      ready_peer(listener.port, context.certificates, node, 0)

    {second_socket, second, _synchronize} =
      ready_peer(listener.port, context.certificates, node, 0)

    refute first.connection_id == second.connection_id
    assert_closed(first_socket)

    eventually(fn ->
      NodeConnections.current(node.id) == %{
        connection_id: second.connection_id,
        state: :ready
      }
    end)

    assert %{connection_id: connection_id} = NodeConnections.current(node.id)
    assert connection_id == second.connection_id
    :ssl.close(second_socket)
  end

  test "one reload replaces one peer identity and abandons another connected node", context do
    listener = start_listener(context.certificates)
    replaced = node_for_certificate(1, context.certificates, 0)
    abandoned = node_for_certificate(2, context.certificates, 2)

    {old_socket, _connected, _synchronize} =
      ready_peer(listener.port, context.certificates, replaced, 0)

    {abandoned_socket, _connected, _synchronize} =
      ready_peer(listener.port, context.certificates, abandoned, 2)

    replacement_identity = Enum.at(context.certificates.nodes, 1).fingerprint

    registrations = [
      registration_for(replaced, peer_identity: replacement_identity),
      registration_for(abandoned, status: :abandoned)
    ]

    Application.put_env(:biot_server, :node_registrations, registrations)
    assert {:ok, _nodes} = Nodes.reload()
    assert_closed(old_socket)
    assert_closed(abandoned_socket)

    stored = Repo.get!(Node, replaced.id)
    assert stored.id == replaced.id
    assert stored.registration == replaced.registration
    assert stored.peer_identity == replacement_identity
    assert Repo.get!(Node, abandoned.id).status == :abandoned

    old_identity = connect(listener.port, context.certificates, 0)
    send_hello(old_identity, replaced.registration, [1])

    assert %Message.Reject{reason: :registration_rejected} =
             await_message(old_identity, :handshake, Message.Reject)

    assert_closed(old_identity)

    {new_identity, _connected, _synchronize} =
      ready_peer(listener.port, context.certificates, stored, 1)

    :ssl.close(new_identity)

    abandoned_identity = connect(listener.port, context.certificates, 2)
    send_hello(abandoned_identity, abandoned.registration, [1])

    assert %Message.Reject{reason: :registration_abandoned} =
             await_message(abandoned_identity, :handshake, Message.Reject)

    assert_closed(abandoned_identity)
  end

  test "status reloads close only connections that lose access service", context do
    listener = start_listener(context.certificates)
    owner = TestFixtures.principal(1)
    actor = TestFixtures.actor(owner)
    node = node_for_certificate(1, context.certificates, 0)
    biot_id = TestFixtures.id(BiotId, 8_040)

    assert {:ok, %Accepted{}} =
             Biots.create(
               actor,
               biot_id,
               TestFixtures.create_command(name: "status-reload", node_id: node.id)
             )

    {enabled_socket, _connected, _synchronize} =
      ready_peer(listener.port, context.certificates, node, 0)

    disabled = registration_for(node, status: :disabled)
    Application.put_env(:biot_server, :node_registrations, [disabled])
    assert {:ok, _nodes} = Nodes.reload()
    assert_closed(enabled_socket)
    assert Repo.get!(BiotRow, biot_id).access_revision == 2

    disabled_node = Repo.get!(Node, node.id)

    {disabled_socket, connected, _synchronize} =
      ready_peer(listener.port, context.certificates, disabled_node, 0)

    Application.put_env(:biot_server, :node_registrations, [])
    assert {:ok, _nodes} = Nodes.reload()
    assert_connection_open(disabled_socket, node.id, connected.connection_id)
    assert Repo.get!(BiotRow, biot_id).access_revision == 2

    Application.put_env(:biot_server, :node_registrations, [registration_for(node, [])])
    assert {:ok, _nodes} = Nodes.reload()
    assert_connection_open(disabled_socket, node.id, connected.connection_id)
    assert Repo.get!(BiotRow, biot_id).access_revision == 2

    Application.put_env(:biot_server, :node_registrations, [])
    assert {:ok, _nodes} = Nodes.reload()
    assert_closed(disabled_socket)
    assert Repo.get!(BiotRow, biot_id).access_revision == 3
  end

  test "synchronize includes only biots that may still have node resources", context do
    listener = start_listener(context.certificates)
    owner = TestFixtures.principal(1)
    node = node_for_certificate(1, context.certificates, 0)

    {active, _environment} =
      TestFixtures.biot(owner, node, 1, desired_state: :running, access_revision: 3)

    {destroyed_unknown, _environment} =
      TestFixtures.biot(owner, node, 2, desired_state: :destroyed, access_revision: 4)

    {destroyed_present, _environment} =
      TestFixtures.biot(owner, node, 3, desired_state: :destroyed, access_revision: 5)

    {destroyed_released, _environment} =
      TestFixtures.biot(owner, node, 4, desired_state: :destroyed, access_revision: 6)

    TestFixtures.observation(destroyed_present, 3, data: :present)
    TestFixtures.observation(destroyed_released, 4, data: :no_allocation)

    socket = connect(listener.port, context.certificates, 0)
    send_hello(socket, node.registration, [1])
    assert %Message.Connected{} = connected = await_message(socket, :handshake, Message.Connected)
    specs = await_snapshot(socket, connected.connection_id)

    revisions =
      Map.new(specs, fn spec ->
        {spec.execution.biot_id, spec.access_revision}
      end)

    assert revisions == %{
             active.id => 3,
             destroyed_unknown.id => 4,
             destroyed_present.id => 5
           }

    refute Map.has_key?(revisions, destroyed_released.id)
    :ssl.close(socket)
  end

  test "access_applied is accepted while synchronizing and new intent arrives on the sweep",
       context do
    listener = start_listener(context.certificates, desired_sweep_interval_ms: 100)
    owner = TestFixtures.principal(1)
    actor = TestFixtures.actor(owner)
    node = node_for_certificate(1, context.certificates, 0)
    socket = connect(listener.port, context.certificates, 0)
    send_hello(socket, node.registration, [1])
    connected = await_message(socket, :handshake, Message.Connected)
    assert [] = await_snapshot(socket, connected.connection_id)

    eventually(fn ->
      match?(%{state: :synchronizing}, NodeConnections.current(node.id))
    end)

    biot_id = TestFixtures.id(BiotId, 8_003)

    assert {:ok, %Accepted{revision: 1}} =
             Biots.create(
               actor,
               biot_id,
               TestFixtures.create_command(name: "mid-sync", node_id: node.id)
             )

    send_message(socket, %Message.AccessApplied{biot_id: biot_id, access_revision: 1}, 1)
    connection_id = connected.connection_id

    eventually(fn ->
      match?(
        %AccessObservation{connection_id: ^connection_id, applied_access_revision: 1},
        Repo.get(AccessObservation, biot_id)
      )
    end)

    # The wake arrives while the connection is still synchronizing, so the handler drops it.
    [{handler, _connection_id}] = Registry.lookup(Biot.Server.Control.Registry, node.id)
    _state = :sys.get_state(handler)
    assert_no_non_heartbeat_message(socket, 1, 100)
    send_message(socket, %Message.Synchronized{connection_id: connected.connection_id}, 1)

    eventually(fn -> match?(%{state: :ready}, NodeConnections.current(node.id)) end)
    assert_no_non_heartbeat_message(socket, 1, 50)

    assert_desired_revision(socket, biot_id, 1)
    assert_desired_revision(socket, biot_id, 1)
    :ssl.close(socket)
  end

  test "the sweep resends a biot behind on access only and stops after access_applied", context do
    listener = start_listener(context.certificates, desired_sweep_interval_ms: 100)
    owner = TestFixtures.principal(1)
    actor = TestFixtures.actor(owner)
    node = node_for_certificate(1, context.certificates, 0)
    socket = connect(listener.port, context.certificates, 0)
    send_hello(socket, node.registration, [1])
    connected = await_message(socket, :handshake, Message.Connected)
    assert [] = await_snapshot(socket, connected.connection_id)

    eventually(fn ->
      match?(%{state: :synchronizing}, NodeConnections.current(node.id))
    end)

    biot_id = TestFixtures.id(BiotId, 8_013)

    assert {:ok, %Accepted{revision: 1}} =
             Biots.create(
               actor,
               biot_id,
               TestFixtures.create_command(name: "accepted", node_id: node.id)
             )

    send_message(socket, %Message.Synchronized{connection_id: connected.connection_id}, 1)
    eventually(fn -> match?(%{state: :ready}, NodeConnections.current(node.id)) end)

    send_message(
      socket,
      %Message.Observation{
        biot_id: biot_id,
        execution_report: TestFixtures.execution_report(accepted_revision: 1)
      },
      1
    )

    connection_id = connected.connection_id

    eventually(fn ->
      match?(
        %Observation{accepted_revision: 1, connection_id: ^connection_id},
        Repo.get(Observation, biot_id)
      )
    end)

    assert_desired_revision(socket, biot_id, 1)
    send_message(socket, %Message.AccessApplied{biot_id: biot_id, access_revision: 1}, 1)

    eventually(fn ->
      match?(%AccessObservation{applied_access_revision: 1}, Repo.get(AccessObservation, biot_id))
    end)

    assert_no_non_heartbeat_message(socket, 1, 250)
    :ssl.close(socket)
  end

  test "committed lifecycle changes wake a ready node and unchanged calls do not", context do
    listener = start_listener(context.certificates)
    owner = TestFixtures.principal(1)
    actor = TestFixtures.actor(owner)
    node = node_for_certificate(1, context.certificates, 0)

    {socket, _connected, _synchronize} =
      ready_peer(listener.port, context.certificates, node, 0)

    biot_id = TestFixtures.id(BiotId, 8_004)

    assert {:ok, %Accepted{revision: 1}} =
             Biots.create(
               actor,
               biot_id,
               TestFixtures.create_command(name: "wake", node_id: node.id)
             )

    assert_desired_revision(socket, biot_id, 1)

    assert {:ok, %Accepted{revision: 2}} = Biots.stop(actor, biot_id, 1)
    assert_desired_revision(socket, biot_id, 2)

    assert {:ok, %Unchanged{revision: 2}} = Biots.stop(actor, biot_id, 2)
    assert_no_non_heartbeat_message(socket, 1, 100)

    assert {:ok, %Accepted{revision: 3}} = Biots.destroy(actor, biot_id)
    assert_desired_revision(socket, biot_id, 3)
    :ssl.close(socket)
  end

  test "observation and resolution reports reach their rows with the connection id", context do
    listener = start_listener(context.certificates)
    owner = TestFixtures.principal(1)
    actor = TestFixtures.actor(owner)
    node = node_for_certificate(1, context.certificates, 0)

    {socket, connected, _synchronize} =
      ready_peer(listener.port, context.certificates, node, 0)

    biot_id = TestFixtures.id(BiotId, 8_005)

    assert {:ok, accepted} =
             Biots.create(
               actor,
               biot_id,
               TestFixtures.create_command(name: "reports", node_id: node.id)
             )

    assert %Message.Desired{biot_spec: spec} = await_message(socket, 1, Message.Desired)

    report =
      TestFixtures.execution_report(
        accepted_revision: accepted.revision,
        installed_environment_id: spec.execution.environment.id,
        container: TestFixtures.running_container(1),
        data: :present
      )

    send_message(
      socket,
      %Message.Observation{biot_id: biot_id, execution_report: report},
      1
    )

    send_message(
      socket,
      %Message.AccessApplied{biot_id: biot_id, access_revision: spec.access_revision},
      1
    )

    manifest = TestFixtures.manifest()

    send_message(
      socket,
      %Message.Resolution{
        environment_id: spec.execution.environment.id,
        manifest: manifest
      },
      1
    )

    eventually(fn ->
      Repo.get!(Environment, spec.execution.environment.id).resolution == {:resolved, manifest}
    end)

    observation = Repo.get!(Observation, biot_id)
    assert observation.connection_id == connected.connection_id
    assert observation.accepted_revision == 1
    assert Repo.get!(AccessObservation, biot_id).connection_id == connected.connection_id
    assert Repo.get!(Operation, accepted.operation_id).outcome == :succeeded

    assert Repo.get!(Environment, spec.execution.environment.id).resolution ==
             {:resolved, manifest}

    :ssl.close(socket)
  end

  test "a node observation stores parsed allocation ids with the connection id", context do
    listener = start_listener(context.certificates)
    owner = TestFixtures.principal(1)
    node = node_for_certificate(1, context.certificates, 0)
    {biot, _environment} = TestFixtures.biot(owner, node, 7)

    {socket, connected, _synchronize} =
      ready_peer(listener.port, context.certificates, node, 0)

    allocation = %OrphanedAllocation{
      biot_id: biot.id,
      uid_range: %{start: 100_000, count: 65_536}
    }

    send_message(socket, %Message.NodeObservation{orphaned_allocations: [allocation]}, 1)

    eventually(fn ->
      match?(%NodeObservation{}, Repo.get(NodeObservation, node.id))
    end)

    observation = Repo.get!(NodeObservation, node.id)
    assert observation.connection_id == connected.connection_id
    assert observation.orphaned_allocations == [allocation]
    :ssl.close(socket)
  end

  test "a report for a biot assigned to another node writes nothing", context do
    listener = start_listener(context.certificates)
    owner = TestFixtures.principal(1)
    node = node_for_certificate(1, context.certificates, 0)
    other_node = node_for_certificate(2, context.certificates, 1)
    {assigned, _environment} = TestFixtures.biot(owner, node, 8)
    {other_biot, _environment} = TestFixtures.biot(owner, other_node, 9)

    {socket, _connected, _synchronize} =
      ready_peer(listener.port, context.certificates, node, 0)

    report = TestFixtures.execution_report()

    send_message(
      socket,
      %Message.Observation{biot_id: other_biot.id, execution_report: report},
      1
    )

    send_message(
      socket,
      %Message.Observation{biot_id: assigned.id, execution_report: report},
      1
    )

    eventually(fn -> match?(%Observation{}, Repo.get(Observation, assigned.id)) end)
    assert Repo.get(Observation, other_biot.id) == nil
    :ssl.close(socket)
  end

  test "the server answers peer heartbeats with the same challenge", context do
    listener = start_listener(context.certificates)
    node = node_for_certificate(1, context.certificates, 0)

    {socket, _connected, _synchronize} =
      ready_peer(listener.port, context.certificates, node, 0)

    send_message(socket, %Message.Heartbeat{challenge: "node-challenge"}, 1)

    assert %Message.HeartbeatResponse{challenge: "node-challenge"} =
             await_message(socket, 1, Message.HeartbeatResponse)

    :ssl.close(socket)
  end

  test "an unanswered server heartbeat closes the connection and clears readiness", context do
    listener =
      start_listener(context.certificates,
        heartbeat_interval_ms: 20,
        heartbeat_timeout_ms: 40
      )

    node = node_for_certificate(1, context.certificates, 0)

    {socket, _connected, _synchronize} =
      ready_peer(listener.port, context.certificates, node, 0)

    assert %Message.Heartbeat{} = await_message(socket, 1, Message.Heartbeat)
    assert_closed(socket)
    eventually(fn -> NodeConnections.current(node.id) == nil end)
  end

  test "a wrong heartbeat response does not satisfy the server challenge", context do
    listener =
      start_listener(context.certificates,
        heartbeat_interval_ms: 20,
        heartbeat_timeout_ms: 60
      )

    node = node_for_certificate(1, context.certificates, 0)

    {socket, _connected, _synchronize} =
      ready_peer(listener.port, context.certificates, node, 0)

    assert %Message.Heartbeat{} = await_message(socket, 1, Message.Heartbeat)
    send_message(socket, %Message.HeartbeatResponse{challenge: "wrong"}, 1)
    assert_closed(socket)
    eventually(fn -> NodeConnections.current(node.id) == nil end)
  end

  test "diagnostic fetch returns bounded content and not-found results", context do
    listener = start_listener(context.certificates)
    owner = TestFixtures.principal(1)
    actor = TestFixtures.actor(owner)
    node = node_for_certificate(1, context.certificates, 0)

    {socket, _connected, _synchronize} =
      ready_peer(listener.port, context.certificates, node, 0)

    diagnostic_ref = failed_operation(actor, node, 8_006, "diagnostic")
    assert %Message.Desired{} = await_message(socket, 1, Message.Desired)
    request = Task.async(fn -> ServerDiagnostics.get(actor, diagnostic_ref) end)
    assert %Message.Diagnostic{} = diagnostic = await_message(socket, 1, Message.Diagnostic)
    assert diagnostic.diagnostic_id == diagnostic_ref
    assert diagnostic.max_bytes == 8

    send_message(
      socket,
      %Message.DiagnosticResult{
        request_id: diagnostic.request_id,
        result: {"12345678", true}
      },
      1
    )

    assert Task.await(request) == {:ok, {"12345678", true}}

    missing_ref = failed_operation(actor, node, 8_007, "missing-diagnostic")
    assert %Message.Desired{} = await_message(socket, 1, Message.Desired)
    missing = Task.async(fn -> ServerDiagnostics.get(actor, missing_ref) end)
    assert %Message.Diagnostic{} = diagnostic = await_message(socket, 1, Message.Diagnostic)

    send_message(
      socket,
      %Message.DiagnosticResult{request_id: diagnostic.request_id, result: :not_found},
      1
    )

    assert Task.await(missing) == {:error, :not_found}
    :ssl.close(socket)
  end

  test "diagnostics return unavailable while disconnected or synchronizing", context do
    listener = start_listener(context.certificates)
    owner = TestFixtures.principal(1)
    actor = TestFixtures.actor(owner)
    node = node_for_certificate(1, context.certificates, 0)
    diagnostic_ref = failed_operation(actor, node, 8_008, "unavailable")

    assert ServerDiagnostics.get(actor, diagnostic_ref) ==
             {:error, :temporarily_unavailable}

    socket = connect(listener.port, context.certificates, 0)
    send_hello(socket, node.registration, [1])
    assert %Message.Connected{} = connected = await_message(socket, :handshake, Message.Connected)
    _specs = await_snapshot(socket, connected.connection_id)

    eventually(fn ->
      match?(%{state: :synchronizing}, NodeConnections.current(node.id))
    end)

    assert ServerDiagnostics.get(actor, diagnostic_ref) ==
             {:error, :temporarily_unavailable}

    NodeConnections.put(node.id, %{
      connection_id: TestFixtures.connection_id(88),
      state: :ready
    })

    assert ServerDiagnostics.get(actor, diagnostic_ref) ==
             {:error, :temporarily_unavailable}

    NodeConnections.delete(node.id)
    :ssl.close(socket)
  end

  test "diagnostic timeout drops a late reply and leaves later requests usable", context do
    listener = start_listener(context.certificates)
    owner = TestFixtures.principal(1)
    actor = TestFixtures.actor(owner)
    node = node_for_certificate(1, context.certificates, 0)

    {socket, _connected, _synchronize} =
      ready_peer(listener.port, context.certificates, node, 0)

    diagnostic_ref = failed_operation(actor, node, 8_009, "timeout")
    assert %Message.Desired{} = await_message(socket, 1, Message.Desired)
    timed_out = Task.async(fn -> ServerDiagnostics.get(actor, diagnostic_ref) end)
    assert %Message.Diagnostic{} = first = await_message(socket, 1, Message.Diagnostic)
    assert Task.await(timed_out) == {:error, :temporarily_unavailable}

    send_message(
      socket,
      %Message.DiagnosticResult{request_id: first.request_id, result: {"late", false}},
      1
    )

    second = Task.async(fn -> ServerDiagnostics.get(actor, diagnostic_ref) end)
    assert %Message.Diagnostic{} = request = await_message(socket, 1, Message.Diagnostic)

    send_message(
      socket,
      %Message.DiagnosticResult{request_id: request.request_id, result: {"next", false}},
      1
    )

    assert Task.await(second) == {:ok, {"next", false}}
    assert %{state: :ready} = NodeConnections.current(node.id)
    :ssl.close(socket)
  end

  test "disconnect releases a pending diagnostic and a new connection remains usable", context do
    listener = start_listener(context.certificates)
    owner = TestFixtures.principal(1)
    actor = TestFixtures.actor(owner)
    node = node_for_certificate(1, context.certificates, 0)

    {socket, _connected, _synchronize} =
      ready_peer(listener.port, context.certificates, node, 0)

    diagnostic_ref = failed_operation(actor, node, 8_013, "disconnect")
    assert %Message.Desired{} = await_message(socket, 1, Message.Desired)
    pending = Task.async(fn -> ServerDiagnostics.get(actor, diagnostic_ref) end)
    assert %Message.Diagnostic{} = await_message(socket, 1, Message.Diagnostic)
    :ssl.close(socket)
    assert Task.await(pending) == {:error, :temporarily_unavailable}
    eventually(fn -> NodeConnections.current(node.id) == nil end)

    {replacement, _connected, _synchronize} =
      ready_peer(listener.port, context.certificates, node, 0)

    next = Task.async(fn -> ServerDiagnostics.get(actor, diagnostic_ref) end)
    assert %Message.Diagnostic{} = request = await_message(replacement, 1, Message.Diagnostic)

    send_message(
      replacement,
      %Message.DiagnosticResult{request_id: request.request_id, result: {"next", false}},
      1
    )

    assert Task.await(next) == {:ok, {"next", false}}
    :ssl.close(replacement)
  end

  test "only the initiating actor and biot owner may fetch a diagnostic", context do
    listener = start_listener(context.certificates)
    owner = TestFixtures.principal(1)
    initiator = TestFixtures.principal(2)
    stranger = TestFixtures.principal(3)
    owner_actor = TestFixtures.actor(owner)
    initiator_actor = TestFixtures.actor(initiator)
    stranger_actor = TestFixtures.actor(stranger)
    node = node_for_certificate(1, context.certificates, 0)

    {socket, _connected, _synchronize} =
      ready_peer(listener.port, context.certificates, node, 0)

    diagnostic_ref = failed_operation(owner_actor, node, 8_010, "authorization")
    assert %Message.Desired{} = await_message(socket, 1, Message.Desired)

    operation = Repo.get_by!(Operation, biot_id: TestFixtures.id(BiotId, 8_010))
    operation |> Ecto.Changeset.change(actor_id: initiator.id) |> Repo.update!()

    for actor <- [owner_actor, initiator_actor] do
      task = Task.async(fn -> ServerDiagnostics.get(actor, diagnostic_ref) end)
      assert %Message.Diagnostic{} = request = await_message(socket, 1, Message.Diagnostic)

      send_message(
        socket,
        %Message.DiagnosticResult{request_id: request.request_id, result: {"ok", false}},
        1
      )

      assert Task.await(task) == {:ok, {"ok", false}}
    end

    assert ServerDiagnostics.get(stranger_actor, diagnostic_ref) == {:error, :forbidden}

    unknown = TestFixtures.id(PrivateDiagnosticId, 99_999)
    assert ServerDiagnostics.get(owner_actor, unknown) == {:error, :not_found}
    :ssl.close(socket)
  end

  test "a real Linux node reconnects, resynchronizes, reports, and serves diagnostics", context do
    case Platform.current() do
      {:ok, _platform} ->
        listener =
          start_listener(context.certificates,
            heartbeat_interval_ms: 20,
            heartbeat_timeout_ms: 50
          )

        owner = TestFixtures.principal(1)
        actor = TestFixtures.actor(owner)
        node = node_for_certificate(1, context.certificates, 0)
        biot_id = TestFixtures.id(BiotId, 8_011)

        assert {:ok, accepted} =
                 Biots.create(
                   actor,
                   biot_id,
                   TestFixtures.create_command(name: "real-node", node_id: node.id)
                 )

        start_node_journal()
        node_pid = start_node(listener.port, context.certificates, node)

        first_connection =
          eventually_value(fn ->
            case NodeConnections.current(node.id) do
              %{state: :ready} = connection -> connection
              _other -> nil
            end
          end)

        first_connection_id = first_connection.connection_id

        receive do
        after
          120 -> :ok
        end

        assert %{connection_id: ^first_connection_id, state: :ready} =
                 NodeConnections.current(node.id)

        spec = eventually_value(fn -> local_intent(biot_id) end)

        report =
          TestFixtures.execution_report(
            accepted_revision: 1,
            installed_environment_id: spec.execution.environment.id,
            container: TestFixtures.running_container(11),
            data: :present
          )

        assert :ok = NodeControl.report_observation(biot_id, report)
        eventually(fn -> Repo.get!(Operation, accepted.operation_id).outcome == :succeeded end)

        diagnostic_ref = NodeDiagnostics.put(TestFixtures.id(BiotId, 8_012), 1, "0123456789")
        _operation = failed_operation(actor, node, 8_012, "real-node-diagnostic", diagnostic_ref)
        assert ServerDiagnostics.get(actor, diagnostic_ref) == {:ok, {"01234567", true}}

        reference = Process.monitor(node_pid)
        Process.exit(node_pid, :kill)
        assert_receive {:DOWN, ^reference, :process, ^node_pid, :killed}
        eventually(fn -> NodeConnections.current(node.id) == nil end)
        assert {:ok, %Accepted{revision: 2}} = Biots.stop(actor, biot_id, 1)

        second_connection =
          eventually_value(fn ->
            case NodeConnections.current(node.id) do
              %{state: :ready} = connection -> connection
              _other -> nil
            end
          end)

        refute second_connection.connection_id == first_connection.connection_id
        eventually(fn -> local_intent(biot_id).execution.desired.revision == 2 end)

      {:error, :unsupported_platform} ->
        assert Platform.current() == {:error, :unsupported_platform}
    end
  end

  test "a real node stages a complete snapshot through its heartbeat and acknowledges in order",
       context do
    case Platform.current() do
      {:ok, _platform} ->
        owner = TestFixtures.principal(41)
        node = node_for_certificate(41, context.certificates, 0)

        {baseline_row, _environment} =
          TestFixtures.biot(owner, node, 8_041, desired_state: :destroyed)

        {next_row, _environment} =
          TestFixtures.biot(owner, node, 8_042, desired_state: :destroyed)

        {:ok, baseline} = Biots.spec(baseline_row.id)
        {:ok, next_spec} = Biots.spec(next_row.id)

        start_node_journal()
        assert {:ok, _intent} = NodeJournal.put_intent(baseline)
        {listener, port} = raw_server(context.certificates)
        parent = self()
        connection_id = TestFixtures.connection_id(41)

        server =
          Task.async(fn ->
            socket = accept_raw_server(listener)
            assert %Message.Hello{} = await_message(socket, :handshake, Message.Hello)

            send_message(
              socket,
              %Message.Connected{connection_id: connection_id, selected_protocol_version: 1},
              :handshake
            )

            send_message(
              socket,
              %Message.SynchronizeBegin{connection_id: connection_id, count: 1},
              1
            )

            send_message(socket, %Message.SynchronizeItem{biot_spec: next_spec}, 1)
            send(parent, :snapshot_staged)

            assert %Message.Heartbeat{challenge: challenge} =
                     await_message(socket, 1, Message.Heartbeat)

            send_message(socket, %Message.HeartbeatResponse{challenge: challenge}, 1)

            receive do
              :finish_snapshot -> :ok
            end

            send_message(socket, %Message.SynchronizeEnd{connection_id: connection_id}, 1)

            assert %Message.AccessApplied{
                     biot_id: biot_id,
                     access_revision: access_revision
                   } = await_message(socket, 1, Message.AccessApplied)

            assert biot_id == next_spec.execution.biot_id
            assert access_revision == next_spec.access_revision

            assert %Message.Synchronized{connection_id: ^connection_id} =
                     await_message(socket, 1, Message.Synchronized)

            :ssl.close(socket)
          end)

        _connection =
          start_node(port, context.certificates, node,
            heartbeat_interval_ms: 20,
            heartbeat_timeout_ms: 500
          )

        assert_receive :snapshot_staged, @eventually_timeout
        assert local_intent(baseline.execution.biot_id) == baseline
        assert local_intent(next_spec.execution.biot_id) == nil
        send(server.pid, :finish_snapshot)
        Task.await(server, @eventually_timeout)

        eventually(fn -> local_intent(next_spec.execution.biot_id) == next_spec end)
        assert local_intent(baseline.execution.biot_id) == nil
        :ssl.close(listener)

      {:error, :unsupported_platform} ->
        assert Platform.current() == {:error, :unsupported_platform}
    end
  end

  test "a real node rejects every invalid snapshot without changing accepted intent", context do
    case Platform.current() do
      {:ok, _platform} ->
        owner = TestFixtures.principal(51)
        node = node_for_certificate(51, context.certificates, 0)

        {baseline_row, _environment} =
          TestFixtures.biot(owner, node, 8_051, desired_state: :destroyed)

        {first_row, _environment} =
          TestFixtures.biot(owner, node, 8_052, desired_state: :destroyed)

        {second_row, _environment} =
          TestFixtures.biot(owner, node, 8_053, desired_state: :destroyed)

        {:ok, baseline} = Biots.spec(baseline_row.id)
        {:ok, first} = Biots.spec(first_row.id)
        {:ok, second} = Biots.spec(second_row.id)
        start_node_journal()
        assert {:ok, _intent} = NodeJournal.put_intent(baseline)

        cases = [
          {:synchronize_count_mismatch,
           fn connection_id ->
             [
               %Message.SynchronizeBegin{connection_id: connection_id, count: 2},
               %Message.SynchronizeItem{biot_spec: first},
               %Message.SynchronizeEnd{connection_id: connection_id}
             ]
           end},
          {:duplicate_biot_id,
           fn connection_id ->
             [
               %Message.SynchronizeBegin{connection_id: connection_id, count: 2},
               %Message.SynchronizeItem{biot_spec: first},
               %Message.SynchronizeItem{biot_spec: first}
             ]
           end},
          {:desired_during_snapshot,
           fn connection_id ->
             [
               %Message.SynchronizeBegin{connection_id: connection_id, count: 1},
               %Message.Desired{biot_spec: first}
             ]
           end},
          {:staged_count_exceeded,
           fn connection_id ->
             [
               %Message.SynchronizeBegin{connection_id: connection_id, count: 1},
               %Message.SynchronizeItem{biot_spec: first},
               %Message.SynchronizeItem{biot_spec: second}
             ]
           end},
          {:snapshot_count_over_capacity,
           fn connection_id ->
             [
               %Message.SynchronizeBegin{
                 connection_id: connection_id,
                 count: Application.fetch_env!(:biot_node, :max_staged_specs) + 1
               }
             ]
           end}
        ]

        for {{reason, actions}, number} <- Enum.with_index(cases, 51) do
          assert_node_snapshot_rejected(
            context.certificates,
            node,
            TestFixtures.connection_id(number),
            reason,
            actions.(TestFixtures.connection_id(number)),
            baseline
          )
        end

      {:error, :unsupported_platform} ->
        assert Platform.current() == {:error, :unsupported_platform}
    end
  end

  test "a real node discards a closed snapshot, reconnects, and restages it", context do
    case Platform.current() do
      {:ok, _platform} ->
        owner = TestFixtures.principal(61)
        node = node_for_certificate(61, context.certificates, 0)

        {baseline_row, _environment} =
          TestFixtures.biot(owner, node, 8_061, desired_state: :destroyed)

        {next_row, _environment} =
          TestFixtures.biot(owner, node, 8_062, desired_state: :destroyed)

        {:ok, baseline} = Biots.spec(baseline_row.id)
        {:ok, next_spec} = Biots.spec(next_row.id)

        start_node_journal()
        assert {:ok, _intent} = NodeJournal.put_intent(baseline)
        {listener, port} = raw_server(context.certificates)
        first_connection = TestFixtures.connection_id(61)
        second_connection = TestFixtures.connection_id(62)
        parent = self()

        server =
          Task.async(fn ->
            first = accept_raw_server(listener)
            complete_node_hello(first, first_connection)

            send_message(
              first,
              %Message.SynchronizeBegin{connection_id: first_connection, count: 1},
              1
            )

            send_message(first, %Message.SynchronizeItem{biot_spec: next_spec}, 1)
            send(parent, :first_snapshot_staged)
            :ssl.close(first)

            replacement = accept_raw_server(listener)
            complete_node_hello(replacement, second_connection)

            send_message(
              replacement,
              %Message.SynchronizeBegin{connection_id: second_connection, count: 1},
              1
            )

            send_message(replacement, %Message.SynchronizeItem{biot_spec: next_spec}, 1)

            send_message(
              replacement,
              %Message.SynchronizeEnd{connection_id: second_connection},
              1
            )

            assert %Message.AccessApplied{} = await_message(replacement, 1, Message.AccessApplied)

            assert %Message.Synchronized{connection_id: ^second_connection} =
                     await_message(replacement, 1, Message.Synchronized)

            :ssl.close(replacement)
          end)

        _connection =
          start_node(port, context.certificates, node,
            reconnect_backoff_min_ms: 20,
            reconnect_backoff_max_ms: 40
          )

        assert_receive :first_snapshot_staged, @eventually_timeout
        assert local_intent(baseline.execution.biot_id) == baseline
        assert local_intent(next_spec.execution.biot_id) == nil
        Task.await(server, @eventually_timeout)
        eventually(fn -> local_intent(next_spec.execution.biot_id) == next_spec end)
        assert local_intent(baseline.execution.biot_id) == nil
        :ssl.close(listener)

      {:error, :unsupported_platform} ->
        assert Platform.current() == {:error, :unsupported_platform}
    end
  end

  test "a disconnected real node coalesces reports and delivers the latest after reconnect",
       context do
    case Platform.current() do
      {:ok, _platform} ->
        listener = start_listener(context.certificates)
        owner = TestFixtures.principal(31)
        actor = TestFixtures.actor(owner)
        node = node_for_certificate(1, context.certificates, 0)
        biot_id = TestFixtures.id(BiotId, 8_031)

        assert {:ok, _accepted} =
                 Biots.create(
                   actor,
                   biot_id,
                   TestFixtures.create_command(name: "outbox-reconnect", node_id: node.id)
                 )

        start_node_journal()

        connection =
          start_node(listener.port, context.certificates, node,
            reconnect_backoff_min_ms: 1_000,
            reconnect_backoff_max_ms: 1_000
          )

        eventually(fn -> match?(%{state: :ready}, NodeConnections.current(node.id)) end)
        spec = eventually_value(fn -> local_intent(biot_id) end)
        environment_id = spec.execution.environment.id

        [{handler, _connection_id}] = Registry.lookup(Biot.Server.Control.Registry, node.id)
        Process.exit(handler, :kill)
        eventually(fn -> NodeControl.status() == :offline end)
        :sys.suspend(connection)

        first =
          TestFixtures.execution_report(
            accepted_revision: 1,
            container: :absent,
            data: :uninitialized
          )

        latest =
          TestFixtures.execution_report(
            accepted_revision: 1,
            installed_environment_id: environment_id,
            container: TestFixtures.running_container(31),
            data: :present
          )

        first_manifest = TestFixtures.manifest(revision_digit: "a")
        latest_manifest = TestFixtures.manifest(revision_digit: "b")

        assert :ok = NodeControl.report_observation(biot_id, first)
        assert :ok = NodeControl.report_observation(biot_id, latest)
        assert :ok = NodeControl.report_resolution(environment_id, first_manifest)
        assert :ok = NodeControl.report_resolution(environment_id, latest_manifest)

        entries = :ets.tab2list(Biot.Node.Control.Outbox)
        assert Enum.count(entries, &match?({{:observation, ^biot_id}, _report}, &1)) == 1
        assert Enum.count(entries, &match?({{:resolution, ^environment_id}, _report}, &1)) == 1

        {:messages, messages} = Process.info(connection, :messages)
        assert Enum.count(messages, &match?({:"$gen_cast", :drain}, &1)) == 1

        :sys.resume(connection)

        eventually(fn -> match?(%{state: :ready}, NodeConnections.current(node.id)) end)

        eventually(fn ->
          case Repo.get(Observation, biot_id) do
            %Observation{container: container, data: :present} ->
              container == latest.container

            _observation ->
              false
          end
        end)

        eventually(fn ->
          case Repo.get!(Environment, environment_id).resolution do
            {:resolved, manifest} -> manifest == latest_manifest
            :unresolved -> false
          end
        end)

      {:error, :unsupported_platform} ->
        assert Platform.current() == {:error, :unsupported_platform}
    end
  end

  test "a real Linux node drops a server that ignores its heartbeat and reconnects", context do
    case Platform.current() do
      {:ok, _platform} ->
        node = node_for_certificate(1, context.certificates, 0)
        {listener, port} = raw_server(context.certificates)
        parent = self()

        server =
          Task.async(fn ->
            socket = accept_raw_server(listener)
            complete_server_handshake(socket)

            assert %Message.NodeObservation{orphaned_allocations: []} =
                     await_message(socket, 1, Message.NodeObservation)

            assert %Message.Heartbeat{} = await_message(socket, 1, Message.Heartbeat)
            assert_closed(socket)
            send(parent, :first_node_connection_timed_out)

            replacement = accept_raw_server(listener)
            assert %Message.Hello{} = await_message(replacement, :handshake, Message.Hello)
            :ssl.close(replacement)
            send(parent, :node_reconnected)
          end)

        start_node_journal()

        _node_pid =
          start_node(port, context.certificates, node,
            heartbeat_interval_ms: 20,
            heartbeat_timeout_ms: 40,
            reconnect_backoff_min_ms: 20,
            reconnect_backoff_max_ms: 40
          )

        assert_receive :first_node_connection_timed_out, @eventually_timeout
        assert_receive :node_reconnected, @eventually_timeout
        Task.await(server, @eventually_timeout)
        :ssl.close(listener)

      {:error, :unsupported_platform} ->
        assert Platform.current() == {:error, :unsupported_platform}
    end
  end

  defp start_listener(certificates, handler_options \\ []) do
    options = [
      id: make_ref(),
      port: 0,
      tls: [
        certfile: certificates.server.cert,
        keyfile: certificates.server.key,
        cacertfile: certificates.ca
      ],
      handler_options:
        Keyword.merge(
          [
            handshake_timeout_ms: 1_000,
            heartbeat_interval_ms: 60_000,
            heartbeat_timeout_ms: 1_000
          ],
          handler_options
        )
    ]

    listener = start_supervised!(Listener.child_spec(options))
    {:ok, {_address, port}} = ThousandIsland.listener_info(listener)
    %{pid: listener, port: port}
  end

  defp node_for_certificate(number, certificates, certificate_index, options \\ []) do
    certificate = Enum.at(certificates.nodes, certificate_index)

    number
    |> TestFixtures.node(options)
    |> Ecto.Changeset.change(peer_identity: certificate.fingerprint)
    |> Repo.update!()
  end

  defp registration_for(node, options) do
    %Registration{
      node_id: node.id,
      registration_id: node.registration,
      peer_identity: Keyword.get(options, :peer_identity, node.peer_identity),
      max_biots: Keyword.get(options, :max_biots, node.max_biots),
      status: Keyword.get(options, :status, node.status)
    }
  end

  defp connect(port, certificates, certificate_index) do
    certificate = Enum.at(certificates.nodes, certificate_index)

    options = [
      verify: :verify_peer,
      cacertfile: certificates.ca,
      certfile: certificate.cert,
      keyfile: certificate.key,
      active: false,
      mode: :binary,
      packet: :raw,
      server_name_indication: :disable
    ]

    {:ok, socket} = :ssl.connect(~c"127.0.0.1", port, options, @receive_timeout)
    socket
  end

  defp ready_peer(port, certificates, node, certificate_index) do
    socket = connect(port, certificates, certificate_index)
    send_hello(socket, node.registration, [1])

    assert %Message.Connected{} =
             connected = await_message(socket, :handshake, Message.Connected)

    specs = await_snapshot(socket, connected.connection_id)

    send_message(socket, %Message.Synchronized{connection_id: connected.connection_id}, 1)

    eventually(fn ->
      NodeConnections.current(node.id) == %{
        connection_id: connected.connection_id,
        state: :ready
      }
    end)

    {socket, connected, specs}
  end

  defp send_hello(socket, registration_id, versions) do
    {:ok, platform} = Platform.parse("aarch64-linux")

    send_message(
      socket,
      %Message.Hello{
        registration_id: registration_id,
        supported_protocol_versions: versions,
        platform: platform
      },
      :handshake
    )
  end

  defp send_message(socket, message, context) do
    {:ok, encoded} = Wire.encode(message, context)
    :ok = :ssl.send(socket, Frame.encode(encoded))
  end

  defp await_message(socket, context, message_module) do
    deadline = System.monotonic_time(:millisecond) + @receive_timeout
    await_message_until(socket, context, message_module, deadline)
  end

  defp await_message_until(socket, context, message_module, deadline) do
    message = receive_message(socket, context, deadline)

    cond do
      is_struct(message, message_module) ->
        message

      match?(%Message.Heartbeat{}, message) ->
        send_message(
          socket,
          %Message.HeartbeatResponse{challenge: message.challenge},
          context
        )

        await_message_until(socket, context, message_module, deadline)

      match?(%Message.HeartbeatResponse{}, message) ->
        await_message_until(socket, context, message_module, deadline)

      true ->
        flunk("expected #{inspect(message_module)}, received: #{inspect(message)}")
    end
  end

  defp assert_no_non_heartbeat_message(socket, context, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    assert_no_non_heartbeat_message_until(socket, context, deadline)
  end

  defp assert_no_non_heartbeat_message_until(socket, context, deadline) do
    case receive_message_result(socket, context, deadline) do
      {:ok, %Message.Heartbeat{challenge: challenge}} ->
        send_message(socket, %Message.HeartbeatResponse{challenge: challenge}, context)
        assert_no_non_heartbeat_message_until(socket, context, deadline)

      {:ok, %Message.HeartbeatResponse{}} ->
        assert_no_non_heartbeat_message_until(socket, context, deadline)

      {:ok, message} ->
        flunk("expected no non-heartbeat message, received: #{inspect(message)}")

      {:error, :timeout} ->
        :ok
    end
  end

  defp receive_message(socket, context, deadline) do
    assert {:ok, message} = receive_message_result(socket, context, deadline)
    message
  end

  defp receive_message_result(socket, context, deadline) do
    with {:ok, <<size::unsigned-big-32>>} <-
           :ssl.recv(socket, 4, remaining_timeout(deadline)),
         {:ok, payload} <- :ssl.recv(socket, size, remaining_timeout(deadline)) do
      Wire.decode(payload, context)
    end
  end

  defp remaining_timeout(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp assert_closed(socket) do
    assert {:error, :closed} = :ssl.recv(socket, 0, @receive_timeout)
  end

  defp assert_connection_open(socket, node_id, connection_id) do
    assert {:error, :timeout} = :ssl.recv(socket, 0, 50)
    assert NodeConnections.current(node_id) == %{connection_id: connection_id, state: :ready}
  end

  defp assert_desired_revision(socket, biot_id, revision) do
    assert %Message.Desired{biot_spec: spec} = await_message(socket, 1, Message.Desired)
    assert spec.execution.biot_id == biot_id
    assert spec.execution.desired.revision == revision
  end

  defp failed_operation(
         actor,
         node,
         number,
         name,
         diagnostic_ref \\ nil
       ) do
    biot_id = TestFixtures.id(BiotId, number)

    assert {:ok, accepted} =
             Biots.create(
               actor,
               biot_id,
               TestFixtures.create_command(name: name, node_id: node.id)
             )

    diagnostic_ref = diagnostic_ref || TestFixtures.id(PrivateDiagnosticId, number)

    failure = %Biot.Protocol.Failure{
      stage: :start,
      code: :container_failed,
      retry: :operator,
      message: "failed",
      diagnostic_ref: diagnostic_ref
    }

    accepted.operation_id
    |> then(&Repo.get!(Operation, &1))
    |> Ecto.Changeset.change(outcome: :failed, failure: failure)
    |> Repo.update!()

    diagnostic_ref
  end

  # The node writes synchronized intent to its journal, so a real node connection needs one. The
  # data root is the only host setting configured, which keeps every controller from starting.
  defp start_node_journal do
    data_root =
      Path.join(System.tmp_dir!(), "biot-node-journal-#{System.unique_integer([:positive])}")

    File.mkdir_p!(data_root)
    previous = Application.get_env(:biot_node, :data_root)
    Application.put_env(:biot_node, :data_root, data_root)

    on_exit(fn ->
      restore_node_env(:data_root, previous)
      File.rm_rf!(data_root)
    end)

    start_supervised!(Biot.Node.Repo)
    start_supervised!(Biot.Node.Journal.Migrator)
    start_supervised!(Biot.Node.Controllers)
    :ok
  end

  defp local_intent(biot_id) do
    case NodeJournal.intent(biot_id) do
      nil -> nil
      intent -> intent.biot_spec
    end
  end

  defp restore_node_env(key, nil), do: Application.delete_env(:biot_node, key)
  defp restore_node_env(key, value), do: Application.put_env(:biot_node, key, value)

  defp start_node(port, certificates, node, options \\ []) do
    certificate = hd(certificates.nodes)

    defaults = [
      server_host: "127.0.0.1",
      server_port: port,
      server_fingerprint: certificates.server.fingerprint,
      registration_id: node.registration,
      tls: [
        certfile: certificate.cert,
        keyfile: certificate.key,
        cacertfile: certificates.ca
      ],
      heartbeat_interval_ms: 60_000,
      heartbeat_timeout_ms: 1_000,
      reconnect_backoff_min_ms: 100,
      reconnect_backoff_max_ms: 200
    ]

    start_supervised!({NodeConnection, Keyword.merge(defaults, options)})
  end

  defp raw_server(certificates) do
    options = [
      certfile: certificates.server.cert,
      keyfile: certificates.server.key,
      cacertfile: certificates.ca,
      verify: :verify_peer,
      fail_if_no_peer_cert: true,
      active: false,
      mode: :binary,
      packet: :raw,
      reuseaddr: true
    ]

    {:ok, listener} = :ssl.listen(0, options)
    {:ok, {_address, port}} = :ssl.sockname(listener)
    {listener, port}
  end

  defp accept_raw_server(listener) do
    {:ok, transport} = :ssl.transport_accept(listener, @receive_timeout)
    {:ok, socket} = :ssl.handshake(transport, @receive_timeout)
    socket
  end

  defp complete_node_hello(socket, connection_id) do
    assert %Message.Hello{} = await_message(socket, :handshake, Message.Hello)

    send_message(
      socket,
      %Message.Connected{connection_id: connection_id, selected_protocol_version: 1},
      :handshake
    )
  end

  defp assert_node_snapshot_rejected(
         certificates,
         node,
         connection_id,
         reason,
         actions,
         baseline
       ) do
    log =
      capture_log(fn ->
        {listener, port} = raw_server(certificates)

        server =
          Task.async(fn ->
            socket = accept_raw_server(listener)
            complete_node_hello(socket, connection_id)
            Enum.each(actions, &send_message(socket, &1, 1))
            assert_closed(socket)
          end)

        _connection =
          start_node(port, certificates, node,
            reconnect_backoff_min_ms: 100,
            reconnect_backoff_max_ms: 200
          )

        Task.await(server, @eventually_timeout)
        :ssl.close(listener)
        eventually(fn -> NodeControl.status() == :offline end)

        receive do
        after
          20 -> :ok
        end

        Logger.flush()
        stop_supervised(NodeConnection)
      end)

    assert log =~ "node control connection disconnected: #{inspect(reason)}"
    assert local_intent(baseline.execution.biot_id) == baseline
  end

  defp complete_server_handshake(socket) do
    assert %Message.Hello{} = await_message(socket, :handshake, Message.Hello)
    connection_id = TestFixtures.connection_id(99)

    send_message(
      socket,
      %Message.Connected{connection_id: connection_id, selected_protocol_version: 1},
      :handshake
    )

    send_message(socket, %Message.SynchronizeBegin{connection_id: connection_id, count: 0}, 1)
    send_message(socket, %Message.SynchronizeEnd{connection_id: connection_id}, 1)

    assert %Message.Synchronized{connection_id: ^connection_id} =
             await_message(socket, 1, Message.Synchronized)
  end

  defp await_snapshot(socket, connection_id) do
    assert %Message.SynchronizeBegin{connection_id: ^connection_id, count: count} =
             await_message(socket, 1, Message.SynchronizeBegin)

    specs =
      for _index <- 1..count//1 do
        assert %Message.SynchronizeItem{biot_spec: spec} =
                 await_message(socket, 1, Message.SynchronizeItem)

        spec
      end

    assert %Message.SynchronizeEnd{connection_id: ^connection_id} =
             await_message(socket, 1, Message.SynchronizeEnd)

    specs
  end

  defp eventually(function, timeout \\ @eventually_timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    eventually_until(function, deadline)
  end

  defp eventually_until(function, deadline) do
    if function.() do
      :ok
    else
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining <= 0 do
        flunk("condition did not become true within the bounded deadline")
      else
        receive do
        after
          min(remaining, 10) -> eventually_until(function, deadline)
        end
      end
    end
  end

  defp eventually_value(function, timeout \\ @eventually_timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    eventually_value_until(function, deadline)
  end

  defp eventually_value_until(function, deadline) do
    case function.() do
      nil -> wait_for_value(function, deadline)
      false -> wait_for_value(function, deadline)
      value -> value
    end
  end

  defp wait_for_value(function, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      flunk("value did not become available within the bounded deadline")
    else
      receive do
      after
        min(remaining, 10) -> eventually_value_until(function, deadline)
      end
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:biot_server, key)
  defp restore_env(key, value), do: Application.put_env(:biot_server, key, value)
end
