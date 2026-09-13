defmodule Biot.Server.SecretsIntegrationTest do
  @moduledoc """
  Drives the server's secret and fetch credential commands against a real database and a real
  mutually authenticated control link, with this test playing the node.
  """

  use Biot.Server.DataCase, async: false

  alias Biot.Protocol.AuthorizationValue
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.Certificates
  alias Biot.Protocol.ExecutionReport
  alias Biot.Protocol.Frame
  alias Biot.Protocol.Message
  alias Biot.Protocol.Platform
  alias Biot.Protocol.RepositorySource
  alias Biot.Protocol.SecretName
  alias Biot.Protocol.SecretValue
  alias Biot.Protocol.Wire
  alias Biot.Server.Access
  alias Biot.Server.Biots
  alias Biot.Server.Biots.Accepted
  alias Biot.Server.Control.Listener
  alias Biot.Server.FetchCredentials
  alias Biot.Server.NodeConnections
  alias Biot.Server.Publications
  alias Biot.Server.Queries
  alias Biot.Server.Queries.SecretView
  alias Biot.Server.Repo
  alias Biot.Server.Reports
  alias Biot.Server.Schema.Biot, as: BiotRow
  alias Biot.Server.Secrets
  alias Biot.Server.TestFixtures

  @receive_timeout 1_000
  @eventually_timeout 2_000

  setup_all do
    directory =
      Path.join(
        System.tmp_dir!(),
        "biot-secrets-integration-#{System.unique_integer([:positive])}"
      )

    {:ok, certificates} = Certificates.generate(directory, 2)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{certificates: certificates}
  end

  setup do
    previous_timeout = Application.get_env(:biot_server, :node_request_timeout_ms)
    Application.put_env(:biot_server, :node_request_timeout_ms, 200)

    on_exit(fn ->
      case previous_timeout do
        nil -> Application.delete_env(:biot_server, :node_request_timeout_ms)
        value -> Application.put_env(:biot_server, :node_request_timeout_ms, value)
      end
    end)

    owner = TestFixtures.principal(1)
    %{owner: owner, actor: TestFixtures.actor(owner)}
  end

  describe "a live link" do
    test "delivers, lists, and removes for the owner", context do
      %{socket: socket, actor: actor, biot_id: biot_id} = live_biot(context, 9_101)

      delivery =
        Task.async(fn -> Secrets.deliver(actor, biot_id, name("DATABASE_URL"), secret()) end)

      assert %Message.DeliverSecret{} = request = await_message(socket, Message.DeliverSecret)
      assert request.biot_id == biot_id
      assert SecretName.to_string(request.name) == "DATABASE_URL"
      assert SecretValue.reveal(request.value) == "s3cret"
      assert request.timeout_ms == 200

      reply(socket, %Message.SecretResult{request_id: request.request_id, result: :ok})
      assert Task.await(delivery) == :ok

      listing = Task.async(fn -> Secrets.list(actor, biot_id) end)
      assert %Message.ListSecrets{} = list_request = await_message(socket, Message.ListSecrets)

      reply(socket, %Message.SecretListResult{
        request_id: list_request.request_id,
        result: {:ok, [name("DATABASE_URL"), name("TOKEN")]}
      })

      assert Task.await(listing) ==
               {:ok, [%SecretView{name: name("DATABASE_URL")}, %SecretView{name: name("TOKEN")}]}

      removal = Task.async(fn -> Secrets.remove(actor, biot_id, name("DATABASE_URL")) end)

      assert %Message.RemoveSecret{} =
               remove_request = await_message(socket, Message.RemoveSecret)

      reply(socket, %Message.SecretResult{request_id: remove_request.request_id, result: :ok})
      assert Task.await(removal) == :ok

      :ssl.close(socket)
    end

    test "delivers and removes a fetch credential without marking exposure", context do
      %{socket: socket, actor: actor, biot_id: biot_id} = live_biot(context, 9_102)

      delivery =
        Task.async(fn -> FetchCredentials.deliver(actor, biot_id, source(), authorization()) end)

      assert %Message.DeliverFetchCredential{} =
               request = await_message(socket, Message.DeliverFetchCredential)

      assert RepositorySource.to_string(request.source) == "https://host.test/org/private.git"
      assert AuthorizationValue.reveal(request.value) == "Bearer abc"

      reply(socket, %Message.FetchCredentialResult{request_id: request.request_id, result: :ok})
      assert Task.await(delivery) == :ok
      refute exposure_marked?(biot_id)

      removal = Task.async(fn -> FetchCredentials.remove(actor, biot_id, source()) end)

      assert %Message.RemoveFetchCredential{} =
               remove_request = await_message(socket, Message.RemoveFetchCredential)

      reply(socket, %Message.FetchCredentialResult{
        request_id: remove_request.request_id,
        result: :ok
      })

      assert Task.await(removal) == :ok
      refute exposure_marked?(biot_id)

      :ssl.close(socket)
    end

    test "no allocation and any failure become temporarily unavailable", context do
      %{socket: socket, actor: actor, biot_id: biot_id} = live_biot(context, 9_103)

      outcomes = [:no_allocation, {:failure, :write_failed}, {:failure, :unavailable}]

      for outcome <- outcomes do
        delivery = Task.async(fn -> Secrets.deliver(actor, biot_id, name("TOKEN"), secret()) end)
        request = await_message(socket, Message.DeliverSecret)
        reply(socket, %Message.SecretResult{request_id: request.request_id, result: outcome})
        assert Task.await(delivery) == {:error, :temporarily_unavailable}

        listing = Task.async(fn -> Secrets.list(actor, biot_id) end)
        list_request = await_message(socket, Message.ListSecrets)

        reply(socket, %Message.SecretListResult{
          request_id: list_request.request_id,
          result: outcome
        })

        assert Task.await(listing) == {:error, :temporarily_unavailable}

        credential =
          Task.async(fn ->
            FetchCredentials.deliver(actor, biot_id, source(), authorization())
          end)

        credential_request = await_message(socket, Message.DeliverFetchCredential)

        reply(socket, %Message.FetchCredentialResult{
          request_id: credential_request.request_id,
          result: outcome
        })

        assert Task.await(credential) == {:error, :temporarily_unavailable}
      end

      :ssl.close(socket)
    end

    test "a request that times out drops its late reply and leaves the link usable", context do
      %{socket: socket, actor: actor, biot_id: biot_id} = live_biot(context, 9_104)

      timed_out = Task.async(fn -> Secrets.deliver(actor, biot_id, name("TOKEN"), secret()) end)
      first = await_message(socket, Message.DeliverSecret)
      assert Task.await(timed_out, 5_000) == {:error, :temporarily_unavailable}
      assert exposure_marked?(biot_id)

      reply(socket, %Message.SecretResult{request_id: first.request_id, result: :ok})

      second = Task.async(fn -> Secrets.deliver(actor, biot_id, name("TOKEN"), secret()) end)
      next = await_message(socket, Message.DeliverSecret)
      assert next.request_id != first.request_id
      reply(socket, %Message.SecretResult{request_id: next.request_id, result: :ok})
      assert Task.await(second) == :ok

      assert %{state: :ready} = NodeConnections.current(node_id(biot_id))
      :ssl.close(socket)
    end

    test "a disconnect releases a pending request", context do
      %{socket: socket, actor: actor, biot_id: biot_id, node: node} = live_biot(context, 9_105)

      pending = Task.async(fn -> Secrets.list(actor, biot_id) end)
      _request = await_message(socket, Message.ListSecrets)
      :ssl.close(socket)

      assert Task.await(pending, 5_000) == {:error, :temporarily_unavailable}
      eventually(fn -> NodeConnections.current(node.id) == nil end)
    end
  end

  describe "the exposure marker" do
    test "is committed before the value is sent and survives a failed delivery", context do
      %{socket: socket, actor: actor, biot_id: biot_id} = live_biot(context, 9_111)

      refute exposure_marked?(biot_id)

      delivery = Task.async(fn -> Secrets.deliver(actor, biot_id, name("TOKEN"), secret()) end)
      request = await_message(socket, Message.DeliverSecret)

      # The node has the frame and has answered nothing, so the only thing that can have set the
      # marker is the transaction that ran before the send.
      assert exposure_marked?(biot_id)

      reply(socket, %Message.SecretResult{
        request_id: request.request_id,
        result: {:failure, :write_failed}
      })

      assert Task.await(delivery) == {:error, :temporarily_unavailable}
      assert exposure_marked?(biot_id)

      :ssl.close(socket)
    end

    test "is not cleared by removal or destruction", context do
      %{socket: socket, actor: actor, biot_id: biot_id} = live_biot(context, 9_112)

      delivery = Task.async(fn -> Secrets.deliver(actor, biot_id, name("TOKEN"), secret()) end)
      request = await_message(socket, Message.DeliverSecret)
      reply(socket, %Message.SecretResult{request_id: request.request_id, result: :ok})
      assert Task.await(delivery) == :ok
      assert exposure_marked?(biot_id)

      removal = Task.async(fn -> Secrets.remove(actor, biot_id, name("TOKEN")) end)
      remove_request = await_message(socket, Message.RemoveSecret)
      reply(socket, %Message.SecretResult{request_id: remove_request.request_id, result: :ok})
      assert Task.await(removal) == :ok
      assert exposure_marked?(biot_id)

      assert {:ok, _accepted} = Biots.destroy(actor, biot_id)
      assert exposure_marked?(biot_id)

      :ssl.close(socket)
    end

    test "is not set when the caller is refused", context do
      %{socket: socket, biot_id: biot_id} = live_biot(context, 9_113)
      stranger = TestFixtures.actor(TestFixtures.principal(2))

      assert Secrets.deliver(nil, biot_id, name("TOKEN"), secret()) ==
               {:error, :unauthenticated}

      # A biot that exists but the actor holds no grant on is forbidden; one that does not exist is
      # not found. Either way the marker stays off, because nothing was sent.
      assert Secrets.deliver(stranger, biot_id, name("TOKEN"), secret()) ==
               {:error, :forbidden}

      assert Secrets.deliver(stranger, TestFixtures.id(BiotId, 9_119), name("TOKEN"), secret()) ==
               {:error, :not_found}

      refute exposure_marked?(biot_id)
      :ssl.close(socket)
    end
  end

  describe "an offline or unready node" do
    test "answers temporarily unavailable and never an empty list", context do
      node = TestFixtures.node(1)
      biot_id = create_biot(context.actor, node, 9_121)

      assert Secrets.list(context.actor, biot_id) == {:error, :temporarily_unavailable}

      assert Secrets.deliver(context.actor, biot_id, name("TOKEN"), secret()) ==
               {:error, :temporarily_unavailable}

      assert Secrets.remove(context.actor, biot_id, name("TOKEN")) ==
               {:error, :temporarily_unavailable}

      assert FetchCredentials.deliver(context.actor, biot_id, source(), authorization()) ==
               {:error, :temporarily_unavailable}

      assert FetchCredentials.remove(context.actor, biot_id, source()) ==
               {:error, :temporarily_unavailable}

      # A delivery attempted against an unreachable node still records that a value may have gone
      # out, because the server cannot prove it did not.
      assert exposure_marked?(biot_id)

      parent = self()
      connection = %{connection_id: TestFixtures.connection_id(7), state: :synchronizing}

      # Only a connection process writes its own entry, so this process stands in for one.
      connection_pid =
        spawn(fn ->
          :ok = NodeConnections.put(node.id, connection)
          send(parent, :synchronizing)

          receive do
            :ready ->
              :ok = NodeConnections.put(node.id, %{connection | state: :ready})
              send(parent, :ready)

              receive do
              end
          end
        end)

      assert_receive :synchronizing
      assert Secrets.list(context.actor, biot_id) == {:error, :temporarily_unavailable}

      send(connection_pid, :ready)
      assert_receive :ready
      reference = Process.monitor(connection_pid)
      Process.exit(connection_pid, :kill)
      assert_receive {:DOWN, ^reference, :process, ^connection_pid, :killed}

      # A killed connection leaves no link, even before the Registry removes its entry.
      assert Secrets.list(context.actor, biot_id) == {:error, :temporarily_unavailable}
    end
  end

  describe "authorization" do
    test "every entry point refuses an unauthenticated caller", context do
      node = TestFixtures.node(1)
      biot_id = create_biot(context.actor, node, 9_131)

      assert Secrets.deliver(nil, biot_id, name("TOKEN"), secret()) == {:error, :unauthenticated}
      assert Secrets.remove(nil, biot_id, name("TOKEN")) == {:error, :unauthenticated}
      assert Secrets.list(nil, biot_id) == {:error, :unauthenticated}

      assert FetchCredentials.deliver(nil, biot_id, source(), authorization()) ==
               {:error, :unauthenticated}

      assert FetchCredentials.remove(nil, biot_id, source()) == {:error, :unauthenticated}
      refute exposure_marked?(biot_id)
    end

    test "a shell collaborator and a view collaborator are forbidden", context do
      node = TestFixtures.node(1)
      biot_id = create_biot(context.actor, node, 9_132)

      shell_principal = TestFixtures.principal(2)
      view_principal = TestFixtures.principal(3)
      shell = TestFixtures.actor(shell_principal)
      view = TestFixtures.actor(view_principal)

      assert {:ok, _grants} = Access.grant_shell(context.actor, biot_id, shell_principal.id)
      assert {:ok, _published} = Publications.publish(context.actor, biot_id, port())

      assert {:ok, _grants} =
               Access.grant_view(context.actor, biot_id, port(), view_principal.id)

      for actor <- [shell, view] do
        assert Secrets.deliver(actor, biot_id, name("TOKEN"), secret()) == {:error, :forbidden}
        assert Secrets.remove(actor, biot_id, name("TOKEN")) == {:error, :forbidden}
        assert Secrets.list(actor, biot_id) == {:error, :forbidden}

        assert FetchCredentials.deliver(actor, biot_id, source(), authorization()) ==
                 {:error, :forbidden}

        assert FetchCredentials.remove(actor, biot_id, source()) == {:error, :forbidden}
      end

      refute exposure_marked?(biot_id)
    end

    test "a biot the actor cannot read is not found", context do
      unknown = TestFixtures.id(BiotId, 9_133)

      assert Secrets.deliver(context.actor, unknown, name("TOKEN"), secret()) ==
               {:error, :not_found}

      assert Secrets.list(context.actor, unknown) == {:error, :not_found}
      assert FetchCredentials.remove(context.actor, unknown, source()) == {:error, :not_found}
    end

    test "a destroyed biot refuses every request", context do
      node = TestFixtures.node(1)
      biot_id = create_biot(context.actor, node, 9_134)
      assert {:ok, _accepted} = Biots.destroy(context.actor, biot_id)

      assert Secrets.deliver(context.actor, biot_id, name("TOKEN"), secret()) ==
               {:error, :destroyed}

      assert Secrets.remove(context.actor, biot_id, name("TOKEN")) == {:error, :destroyed}
      assert Secrets.list(context.actor, biot_id) == {:error, :destroyed}

      assert FetchCredentials.deliver(context.actor, biot_id, source(), authorization()) ==
               {:error, :destroyed}

      assert FetchCredentials.remove(context.actor, biot_id, source()) == {:error, :destroyed}
      refute exposure_marked?(biot_id)
    end
  end

  describe "waiting_for" do
    test "is stored from a report and shown in the biot view", context do
      node = TestFixtures.node(1)
      biot_id = create_biot(context.actor, node, 9_141)
      connection_id = TestFixtures.connection_id(9)
      :ok = NodeConnections.put(node.id, %{connection_id: connection_id, state: :ready})
      on_exit(fn -> NodeConnections.delete(node.id) end)

      waiting = %ExecutionReport{
        accepted_revision: 1,
        installed_environment_id: nil,
        container: :absent,
        data: :present,
        waiting_for: {:fetch_credential, source()},
        failure: nil
      }

      assert {:ok, _stored} = Reports.observation(node.id, connection_id, biot_id, waiting)

      assert {:ok, view} = Queries.Biots.get(context.actor, biot_id)
      assert view.actual.waiting_for == {:fetch_credential, source()}
      assert view.actual.failure == nil

      # A wait is not a failure, so the operation the report answers is not completed by it.
      assert view.operation.outcome in [:pending, :working]

      cleared = %{waiting | waiting_for: nil}

      assert {:ok, _cleared_stored} =
               Reports.observation(node.id, connection_id, biot_id, cleared)

      assert {:ok, after_clear} = Queries.Biots.get(context.actor, biot_id)
      assert after_clear.actual.waiting_for == nil
    end
  end

  defp live_biot(context, number) do
    listener = start_listener(context.certificates)
    node = node_for_certificate(1, context.certificates, 0)
    biot_id = create_biot(context.actor, node, number)
    {socket, _connected} = ready_peer(listener.port, context.certificates, node)

    %{socket: socket, actor: context.actor, biot_id: biot_id, node: node}
  end

  defp create_biot(actor, node, number) do
    biot_id = TestFixtures.id(BiotId, number)

    assert {:ok, %Accepted{}} =
             Biots.create(
               actor,
               biot_id,
               TestFixtures.create_command(name: "biot-#{number}", node_id: node.id)
             )

    biot_id
  end

  defp exposure_marked?(biot_id) do
    Repo.get!(BiotRow, biot_id).direct_secret_exposure_possible
  end

  defp node_id(biot_id), do: Repo.get!(BiotRow, biot_id).node_id

  defp name(value) do
    {:ok, name} = SecretName.parse(value)
    name
  end

  defp secret do
    {:ok, value} = SecretValue.parse("s3cret", 1)
    value
  end

  defp authorization do
    {:ok, value} = AuthorizationValue.parse("Bearer abc", 1)
    value
  end

  defp source do
    {:ok, source} = RepositorySource.parse("https://host.test/org/private.git")
    source
  end

  defp port do
    {:ok, port} = Biot.Protocol.Port.parse(8_080)
    port
  end

  defp start_listener(certificates) do
    options = [
      id: make_ref(),
      port: 0,
      tls: [
        certfile: certificates.server.cert,
        keyfile: certificates.server.key,
        cacertfile: certificates.ca
      ],
      handler_options: [
        handshake_timeout_ms: 1_000,
        heartbeat_interval_ms: 60_000,
        heartbeat_timeout_ms: 1_000
      ]
    ]

    listener = start_supervised!(Listener.child_spec(options))
    {:ok, {_address, port}} = ThousandIsland.listener_info(listener)
    %{pid: listener, port: port}
  end

  defp node_for_certificate(number, certificates, certificate_index) do
    certificate = Enum.at(certificates.nodes, certificate_index)

    number
    |> TestFixtures.node()
    |> Ecto.Changeset.change(peer_identity: certificate.fingerprint)
    |> Repo.update!()
  end

  defp ready_peer(port, certificates, node) do
    socket = connect(port, certificates, 0)
    {:ok, platform} = Platform.parse("aarch64-linux")

    send_message(
      socket,
      %Message.Hello{
        registration_id: node.registration,
        supported_protocol_versions: [1],
        platform: platform
      },
      :handshake
    )

    assert %Message.Connected{} =
             connected = await_message(socket, Message.Connected, :handshake)

    await_snapshot(socket, connected.connection_id)
    send_message(socket, %Message.Synchronized{connection_id: connected.connection_id}, 1)

    eventually(fn ->
      NodeConnections.current(node.id) == %{
        connection_id: connected.connection_id,
        state: :ready
      }
    end)

    {socket, connected}
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

  defp await_snapshot(socket, connection_id) do
    assert %Message.SynchronizeBegin{connection_id: ^connection_id, count: count} =
             await_message(socket, Message.SynchronizeBegin)

    for _index <- 1..count//1 do
      assert %Message.SynchronizeItem{} = await_message(socket, Message.SynchronizeItem)
    end

    assert %Message.SynchronizeEnd{connection_id: ^connection_id} =
             await_message(socket, Message.SynchronizeEnd)
  end

  defp reply(socket, message), do: send_message(socket, message, 1)

  defp send_message(socket, message, context) do
    {:ok, encoded} = Wire.encode(message, context)
    :ok = :ssl.send(socket, Frame.encode(encoded))
  end

  defp await_message(socket, module, context \\ 1) do
    deadline = System.monotonic_time(:millisecond) + @receive_timeout
    await_message_until(socket, module, context, deadline)
  end

  defp await_message_until(socket, module, context, deadline) do
    message = receive_message(socket, context, deadline)

    cond do
      is_struct(message, module) ->
        message

      match?(%Message.Heartbeat{}, message) ->
        send_message(socket, %Message.HeartbeatResponse{challenge: message.challenge}, context)
        await_message_until(socket, module, context, deadline)

      match?(%Message.Observation{}, message) or match?(%Message.NodeObservation{}, message) ->
        await_message_until(socket, module, context, deadline)

      true ->
        flunk("expected #{inspect(module)}, received: #{inspect(message)}")
    end
  end

  defp receive_message(socket, context, deadline) do
    assert {:ok, <<size::unsigned-big-32>>} =
             :ssl.recv(socket, 4, max(deadline - System.monotonic_time(:millisecond), 0))

    assert {:ok, payload} =
             :ssl.recv(socket, size, max(deadline - System.monotonic_time(:millisecond), 0))

    assert {:ok, message} = Wire.decode(payload, context)
    message
  end

  defp eventually(function, timeout \\ @eventually_timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    eventually_until(function, deadline)
  end

  defp eventually_until(function, deadline) do
    cond do
      function.() -> :ok
      System.monotonic_time(:millisecond) >= deadline -> flunk("condition never became true")
      true -> Process.sleep(10) && eventually_until(function, deadline)
    end
  end
end
