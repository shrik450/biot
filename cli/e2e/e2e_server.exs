# Stands up a real dev server plus a real control-protocol peer (a "fake node")
# for the Go CLI end-to-end suite, and holds until killed.
#
#   MIX_ENV=dev mix run --no-start cli/e2e/e2e_server.exs
#
# The peer speaks the real wire protocol over real mutual TLS. It accepts a
# desired spec, reports a healthy observation for it, accepts every secret and
# fetch-credential delivery, and serves a shell stream for `biot ssh`. Nothing
# here reaches Nix; a node that would build an environment is past the boundary
# the CLI can see.
#
# It prints SERVER_URL, TOKEN, NODE_ID, and the rest, then READY, and keeps
# answering until killed.

# The fixtures name their scratch files with `BiotTest.Temp`, which only the test environment
# compiles, so this dev-environment script loads it the same way it loads them, first because they
# depend on it.
Code.require_file("../../apps/biot_protocol/test/support/temp.ex", __DIR__)

support = Path.join([__DIR__, "..", "..", "apps", "biot_server", "test", "support"])
Code.require_file(Path.join(support, "fixtures.ex"))
Code.require_file(Path.join(support, "access_harness.ex"))

defmodule E2EServer do
  alias Biot.Protocol.{
    BiotId,
    ExecutionReport,
    Frame,
    Message,
    NodeId,
    RegistrationId,
    ShellFrame,
    Wire
  }

  alias Biot.Server.{AccessHarness, Biots, Credentials, Repo, TestFixtures}
  alias Biot.Server.Biots.Create
  alias Biot.Server.Schema.{Node, Principal}

  @ready_context 1

  def main do
    port = free_port()

    directory =
      Path.join(System.tmp_dir!(), "biot-e2e-#{System.system_time(:microsecond)}-#{System.pid()}")

    File.rm_rf!(directory)
    File.mkdir_p!(directory)
    {:ok, certificates} = TestFixtures.certificates(directory, 2)
    host_key = generate_host_key(directory)

    # Enroll both nodes through the operator file before startup. The startup
    # reconciliation disables every node the file does not name, so an
    # unenrolled node would go disabled moments after it is inserted.
    node_number = 2_000_000 + :rand.uniform(1_000_000)
    offline_number = 3_000_000 + :rand.uniform(1_000_000)
    node_id = TestFixtures.id(NodeId, node_number)
    offline_id = TestFixtures.id(NodeId, offline_number)

    TestFixtures.put_registrations([
      registration(node_id, node_number, Enum.at(certificates.nodes, 0).fingerprint),
      registration(offline_id, offline_number, Enum.at(certificates.nodes, 1).fingerprint)
    ])

    # The server migrates its database at boot, so a fresh file inside this run's own directory is
    # a migrated one. Without this the script seeds a developer's own dev database with fixtures.
    repo = Application.fetch_env!(:biot_server, Repo)

    Application.put_env(
      :biot_server,
      Repo,
      Keyword.put(repo, :database, Path.join(directory, "e2e.sqlite3"))
    )

    Application.put_env(:biot_server, :control_port, port)

    Application.put_env(:biot_server, :control_tls,
      certfile: certificates.server.cert,
      keyfile: certificates.server.key,
      cacertfile: certificates.ca
    )

    # The SSH daemon is off in dev for the same reason the control listener is:
    # both settings are nil in config/config.exs. Fill them in before startup.
    ssh_port = free_port()
    Application.put_env(:biot_server, :ssh_host_key_file, host_key)
    Application.put_env(:biot_server, :ssh_port, ssh_port)

    endpoint = Application.fetch_env!(:biot_web, BiotWeb.Endpoint)
    # The dev config leaves the endpoint's port unset, so without this the script would announce
    # Phoenix's 4000 whatever else is running there.
    http_port = free_port()

    endpoint =
      endpoint
      |> Keyword.put(:code_reloader, false)
      |> Keyword.put(:server, true)
      |> Keyword.put(:watchers, [])
      |> Keyword.update!(:http, &Keyword.put(&1, :port, http_port))

    Application.put_env(:biot_web, BiotWeb.Endpoint, endpoint)
    {:ok, _} = Application.ensure_all_started(:biot_web)

    principal = enabled_principal(9100)
    {_session, authentication} = AccessHarness.control(principal)
    expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)
    {:ok, created} = Credentials.create(authentication, "cli-e2e", expires_at)
    {:ok, second} = Credentials.create(authentication, "second", expires_at)
    _teammate = enabled_principal(9101, "teammate@example.test")

    node = Repo.get!(Node, node_id)
    peer = AccessHarness.ready_peer(port, certificates, node, 0)

    # A second enabled node with no peer: it accepts a Biot but every delivery
    # to it fails, which is the failure path the secret tests exercise.
    offline_node = Repo.get!(Node, offline_id)
    offline_name = "offline-#{:rand.uniform(1_000_000)}"

    {:ok, _accepted} =
      Biots.create(
        TestFixtures.actor(principal),
        TestFixtures.id(BiotId, 4_000_000 + :rand.uniform(1_000_000)),
        %Create{
          name: TestFixtures.biot_name(offline_name),
          repository: TestFixtures.repository(),
          environment: TestFixtures.selection(),
          node_id: offline_node.id,
          initial_state: :running
        }
      )

    IO.puts("SERVER_URL=http://localhost:#{http_port}")
    IO.puts("TOKEN=#{created.token}")
    IO.puts("SECOND_TOKEN=#{second.token}")
    IO.puts("SECOND_CREDENTIAL_ID=#{second.credential.id}")
    IO.puts("SHARE_EMAIL=teammate@example.test")
    IO.puts("NODE_ID=#{node.id}")
    IO.puts("BIOT_NAME=#{offline_name}")
    IO.puts("SSH_PORT=#{ssh_port}")
    IO.puts("READY")
    IO.puts("")

    serve(peer, peer.socket, @ready_context)
  end

  # The node's side of the control protocol: answer heartbeats, report a healthy
  # observation for each desired spec, and accept every delivery. A stream is
  # served in its own process so the control loop keeps answering.
  defp serve(peer, socket, context) do
    case read_frame(socket, context) do
      {:ok, %Message.Heartbeat{challenge: challenge}} ->
        send_message(socket, %Message.HeartbeatResponse{challenge: challenge}, context)
        serve(peer, socket, context)

      {:ok, %Message.Desired{biot_spec: spec}} ->
        report_desired(socket, spec, context)
        serve(peer, socket, context)

      {:ok, %Message.DeliverSecret{request_id: request_id}} ->
        send_message(socket, %Message.SecretResult{request_id: request_id, result: :ok}, context)
        serve(peer, socket, context)

      {:ok, %Message.DeliverFetchCredential{request_id: request_id}} ->
        send_message(
          socket,
          %Message.FetchCredentialResult{request_id: request_id, result: :ok},
          context
        )

        serve(peer, socket, context)

      {:ok, %Message.RemoveSecret{request_id: request_id}} ->
        send_message(socket, %Message.SecretResult{request_id: request_id, result: :ok}, context)
        serve(peer, socket, context)

      {:ok, %Message.RemoveFetchCredential{request_id: request_id}} ->
        send_message(
          socket,
          %Message.FetchCredentialResult{request_id: request_id, result: :ok},
          context
        )

        serve(peer, socket, context)

      {:ok, %Message.ListSecrets{request_id: request_id}} ->
        send_message(
          socket,
          %Message.SecretListResult{request_id: request_id, result: {:ok, []}},
          context
        )

        serve(peer, socket, context)

      {:ok, %Message.Diagnostic{request_id: request_id}} ->
        send_message(
          socket,
          %Message.DiagnosticResult{request_id: request_id, result: :not_found},
          context
        )

        serve(peer, socket, context)

      {:ok, %Message.RuntimeLogs{request_id: request_id}} ->
        send_message(
          socket,
          %Message.RuntimeLogsResult{request_id: request_id, result: :not_found},
          context
        )

        serve(peer, socket, context)

      {:ok, %Message.OpenStream{stream_id: stream_id, target: target}} ->
        spawn(fn -> serve_stream(peer, stream_id, target) end)
        serve(peer, socket, context)

      {:ok, message} ->
        IO.puts("node: unhandled #{inspect(message.__struct__)}")
        serve(peer, socket, context)

      {:error, reason} ->
        IO.puts("node: control connection closed: #{inspect(reason)}")
    end
  end

  defp serve_stream(peer, stream_id, {:shell, request}) do
    socket = AccessHarness.attach(peer, stream_id)

    case request.command do
      nil -> echo_stream(socket)
      command -> run_command(socket, command)
    end
  rescue
    error -> IO.puts("node: shell stream failed: #{inspect(error)}")
  end

  defp serve_stream(_peer, _stream_id, {:port, _port}), do: :ok

  # The command came in the stream target, so the node answers it directly. It
  # is a protocol peer, not a Nix node: it runs the handful of commands the
  # suite drives and reports 127 for the rest, which is what a shell entry would
  # report for a command it cannot find.
  defp run_command(socket, command) do
    {output, status} = execute(command)
    send_shell_frame(socket, {:data, output})
    send_shell_frame(socket, {:exit, status})
    :ssl.close(socket)
  end

  defp echo_stream(socket) do
    case read_shell_frame(socket) do
      {:ok, {:data, data}} ->
        send_shell_frame(socket, {:data, data})
        echo_stream(socket)

      {:ok, {:resize, _cols, _rows}} ->
        echo_stream(socket)

      {:ok, {:exit, status}} ->
        send_shell_frame(socket, {:exit, status})
        :ssl.close(socket)

      {:error, _reason} ->
        :ok
    end
  end

  defp execute(["echo" | arguments]), do: {Enum.join(arguments, " ") <> "\n", 0}
  defp execute(["true"]), do: {"", 0}
  defp execute(["false"]), do: {"", 1}
  defp execute([command | _arguments]), do: {"#{command}: command not found\n", 127}

  defp send_shell_frame(socket, frame) do
    {:ok, encoded} = ShellFrame.encode(frame)
    :ok = :ssl.send(socket, encoded)
  end

  defp read_shell_frame(socket) do
    with {:ok, header} <- :ssl.recv(socket, 5, :infinity),
         <<type::8, length::unsigned-big-32>> = header,
         {:ok, payload} <- :ssl.recv(socket, length, :infinity),
         {:ok, [frame], <<>>} <-
           ShellFrame.decode(<<type, length::unsigned-big-32, payload::binary>>, :to_agent) do
      {:ok, frame}
    end
  end

  defp report_desired(socket, spec, context) do
    execution = spec.execution
    desired = execution.desired
    environment_id = execution.environment.id

    send_message(
      socket,
      %Message.AccessApplied{biot_id: execution.biot_id, access_revision: spec.access_revision},
      context
    )

    send_message(
      socket,
      %Message.Resolution{environment_id: environment_id, manifest: TestFixtures.manifest()},
      context
    )

    report = %ExecutionReport{
      accepted_revision: desired.revision,
      installed_environment_id: environment_id,
      container: container(desired.state),
      data: data(desired.state),
      waiting_for: nil,
      failure: nil
    }

    send_message(
      socket,
      %Message.Observation{biot_id: execution.biot_id, execution_report: report},
      context
    )
  end

  defp container(:running), do: {:present, TestFixtures.incarnation_id(1), :running}
  defp container(_state), do: :absent

  defp data(:destroyed), do: :no_allocation
  defp data(_state), do: :present

  defp send_message(socket, message, context) do
    {:ok, encoded} = Wire.encode(message, context)
    :ok = :ssl.send(socket, Frame.encode(encoded))
  end

  defp read_frame(socket, context) do
    with {:ok, <<size::unsigned-big-32>>} <- :ssl.recv(socket, 4, :infinity),
         {:ok, payload} <- :ssl.recv(socket, size, :infinity),
         {:ok, message} <- Wire.decode(payload, context) do
      {:ok, message}
    end
  end

  defp registration(node_id, node_number, fingerprint) do
    %{
      "node_id" => to_string(node_id),
      "registration_id" => to_string(TestFixtures.id(RegistrationId, node_number + 1_000)),
      "peer_identity" => fingerprint,
      "max_biots" => 1000,
      "status" => "enabled"
    }
  end

  defp enabled_principal(number, email \\ nil) do
    id = TestFixtures.id(Biot.Protocol.PrincipalId, number)

    Repo.get(Principal, id) ||
      TestFixtures.principal(number, if(email, do: [email: email], else: []))
  end

  defp generate_host_key(directory) do
    path = Path.join(directory, "ssh_host_ed25519_key")

    case System.cmd("ssh-keygen", ["-t", "ed25519", "-N", "", "-f", path, "-q"],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> path
      {output, status} -> raise "ssh-keygen failed (#{status}): #{output}"
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end

E2EServer.main()
