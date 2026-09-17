defmodule Biot.Server.SshDaemonIntegrationTest do
  use Biot.Server.DataCase, async: false

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.ShellFrame
  alias Biot.Server.{AccessHarness, SshKeys}
  alias Biot.Server.Ssh.Daemon
  alias Biot.Server.TestFixtures

  @timeout 8_000

  setup_all do
    directory = Path.join(System.tmp_dir!(), "biot-ssh-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    host_key = Path.join(directory, "host")
    user_key = Path.join(directory, "user")
    unknown_key = Path.join(directory, "unknown")

    for path <- [host_key, user_key, unknown_key] do
      {output, 0} = System.cmd("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", path])
      assert output == ""
    end

    on_exit(fn -> File.rm_rf!(directory) end)

    %{host_key: host_key, user_key: user_key, unknown_key: unknown_key}
  end

  setup %{host_key: host_key, user_key: user_key, unknown_key: unknown_key} do
    previous_host_key = Application.get_env(:biot_server, :ssh_host_key_file)
    previous_port = Application.get_env(:biot_server, :ssh_port)
    port = free_port()
    Application.put_env(:biot_server, :ssh_host_key_file, host_key)
    Application.put_env(:biot_server, :ssh_port, port)
    {:ok, daemon} = Daemon.start_link()
    on_exit(fn -> stop_daemon(daemon, previous_host_key, previous_port) end)

    directory = Path.dirname(host_key)
    certificate_directory = Path.join(directory, "node-#{System.unique_integer([:positive])}")
    {:ok, certificates} = TestFixtures.certificates(certificate_directory, 1)
    listener_port = AccessHarness.start_listener(certificates)
    node = AccessHarness.node_row(1, certificates, 0)
    owner = TestFixtures.principal(1)
    collaborator = TestFixtures.principal(2)
    {biot, _environment} = TestFixtures.biot(owner, node, 1)
    TestFixtures.observation(biot, 1, container: TestFixtures.running_container(1))
    peer = AccessHarness.ready_peer(listener_port, certificates, node, 0)

    public_key = String.trim(File.read!(user_key <> ".pub"))
    {:ok, key} = SshKeys.add(TestFixtures.actor(owner), public_key, "test-key")

    on_exit(fn -> :ssl.close(peer.socket) end)

    %{
      daemon: daemon,
      port: port,
      host_key: host_key,
      peer: peer,
      owner: owner,
      collaborator: collaborator,
      biot: biot,
      user: BiotId.to_string(biot.id),
      key: key,
      user_key: user_key,
      unknown_key: unknown_key
    }
  end

  test "a registered key opens a shell and the node may speak first", context do
    task = ssh_task(context, ["-tt", "--", "cat"])
    open = AccessHarness.await_open(context.peer)
    attach = AccessHarness.attach(context.peer, open.stream_id)

    send_data(attach, "node-first\n")
    send_exit(attach, 0)

    assert {output, 0} = Task.await(task, @timeout)
    assert output =~ "node-first"
  end

  test "an unregistered key is refused", context do
    result = ssh(context, context.unknown_key, ["--", "true"])
    assert elem(result, 1) == 255
    AccessHarness.no_message(context.peer, Biot.Protocol.Message.OpenStream, 500)
  end

  test "exec returns the agent's non-zero exit status", context do
    task = ssh_task(context, ["--", "exit", "3"])
    open = AccessHarness.await_open(context.peer)
    attach = AccessHarness.attach(context.peer, open.stream_id)
    send_exit(attach, 3)

    assert {_output, 3} = Task.await(task, @timeout)
  end

  test "closed stdin sends terminal EOF and cat does not hang", context do
    command = ssh_command(context, context.user_key, ["--", "cat"])

    task =
      Task.async(fn ->
        System.cmd("sh", ["-c", command <> " < /dev/null"], stderr_to_stdout: true)
      end)

    open = AccessHarness.await_open(context.peer)
    attach = AccessHarness.attach(context.peer, open.stream_id)

    assert {:data, <<4>>} = recv_agent_data(attach)
    send_exit(attach, 0)
    assert {_output, 0} = Task.await(task, @timeout)
  end

  test "port forwarding is refused", context do
    local_port = free_port()

    task =
      Task.async(fn ->
        System.cmd(
          "timeout",
          ["5", "ssh"] ++
            ssh_options(context, context.user_key) ++
            [
              "-o",
              "ExitOnForwardFailure=yes",
              "-N",
              "-L",
              "127.0.0.1:#{local_port}:127.0.0.1:22",
              context.user <> "@127.0.0.1"
            ],
          stderr_to_stdout: true
        )
      end)

    assert {:ok, forwarded_socket} = wait_for_tcp_listener(local_port)
    assert {:error, :closed} = :gen_tcp.recv(forwarded_socket, 0, 1_000)
    :gen_tcp.close(forwarded_socket)

    {output, 124} = Task.await(task, 7_000)
    assert output =~ "Forwarding disabled"
    assert {:error, :econnrefused} = wait_for_tcp_closed(local_port)

    AccessHarness.no_message(context.peer, Biot.Protocol.Message.OpenStream, 500)
  end

  test "sftp is refused", context do
    sftp =
      System.cmd(
        "timeout",
        ["5", "sftp"] ++ sftp_options(context, context.user_key) ++ [context.user <> "@127.0.0.1"],
        stderr_to_stdout: true
      )

    {sftp_output, sftp_status} = sftp
    assert sftp_status not in [0, 124]
    assert sftp_output =~ "subsystem"
    AccessHarness.no_message(context.peer, Biot.Protocol.Message.OpenStream, 500)
  end

  test "removing a key closes its live SSH connection", context do
    task = ssh_task(context, ["--", "cat"])
    open = AccessHarness.await_open(context.peer)
    attach = AccessHarness.attach(context.peer, open.stream_id)
    assert Process.alive?(task.pid)

    assert :ok = SshKeys.remove(TestFixtures.actor(context.owner), context.key.id)
    assert AccessHarness.closed?(attach)
    assert elem(Task.await(task, @timeout), 1) != 0
  end

  test "a peer that closes a stream without an exit frame fails the SSH command", context do
    task = ssh_task(context, ["--", "cat"])
    open = AccessHarness.await_open(context.peer)
    attach = AccessHarness.attach(context.peer, open.stream_id)

    assert :ok = :ssl.close(attach)
    assert {_output, status} = Task.await(task, @timeout)
    assert status != 0
  end

  test "the daemon keeps serving its pinned host key after the file is rotated", context do
    original = ssh_keyscan(context.port)
    rotated = Path.join(Path.dirname(context.host_key), "rotated-host")

    {output, 0} = System.cmd("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", rotated])
    assert output == ""
    File.cp!(rotated, context.host_key)

    assert ssh_keyscan(context.port) == original
  end

  test "stopping the daemon leaves the server supervisor alive", context do
    supervisor = Process.whereis(Biot.Server.Supervisor)
    assert is_pid(supervisor)
    assert Process.alive?(supervisor)
    assert :ok = GenServer.stop(context.daemon, :normal, @timeout)
    refute Process.alive?(context.daemon)
    assert Process.alive?(supervisor)
  end

  defp ssh_task(context, command),
    do: Task.async(fn -> ssh(context, context.user_key, command) end)

  defp ssh(context, key_path, args) do
    System.cmd("ssh", ssh_options(context, key_path) ++ [context.user <> "@127.0.0.1" | args],
      stderr_to_stdout: true
    )
  end

  defp ssh_command(context, key_path, args) do
    ["ssh" | ssh_options(context, key_path) ++ [context.user <> "@127.0.0.1" | args]]
    |> Enum.map_join(" ", &shell_quote/1)
  end

  defp ssh_options(context, key_path) do
    [
      "-p",
      Integer.to_string(context.port),
      "-i",
      key_path,
      "-o",
      "BatchMode=yes",
      "-o",
      "IdentitiesOnly=yes",
      "-o",
      "StrictHostKeyChecking=no",
      "-o",
      "UserKnownHostsFile=/dev/null",
      "-o",
      "ConnectTimeout=3"
    ]
  end

  defp ssh_keyscan(port) do
    {output, 0} =
      System.cmd("ssh-keyscan", ["-T", "5", "-p", Integer.to_string(port), "127.0.0.1"],
        stderr_to_stdout: true
      )

    output
    |> String.split("\n")
    |> Enum.find(&String.contains?(&1, "ssh-ed25519"))
    |> case do
      nil -> flunk("ssh-keyscan returned no ed25519 host key: #{output}")
      line -> line
    end
  end

  defp sftp_options(context, key_path) do
    [
      "-P",
      Integer.to_string(context.port),
      "-i",
      key_path,
      "-o",
      "BatchMode=yes",
      "-o",
      "IdentitiesOnly=yes",
      "-o",
      "StrictHostKeyChecking=no",
      "-o",
      "UserKnownHostsFile=/dev/null",
      "-o",
      "ConnectTimeout=3"
    ]
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp send_data(socket, data) do
    {:ok, frame} = ShellFrame.encode({:data, data})
    :ok = :ssl.send(socket, frame)
  end

  defp send_exit(socket, status) do
    {:ok, frame} = ShellFrame.encode({:exit, status})
    :ok = :ssl.send(socket, frame)
  end

  defp recv_agent_data(socket) do
    {:ok, <<type, length::unsigned-big-32>>} = :ssl.recv(socket, 5, @timeout)
    {:ok, payload} = :ssl.recv(socket, length, @timeout)

    {:ok, [frame], <<>>} =
      ShellFrame.decode(<<type, length::unsigned-big-32, payload::binary>>, :to_agent)

    frame
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp wait_for_tcp_listener(port, attempts \\ 20)
  defp wait_for_tcp_listener(_port, 0), do: {:error, :timeout}

  defp wait_for_tcp_listener(port, attempts) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 100) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, :econnrefused} ->
        Process.sleep(50)
        wait_for_tcp_listener(port, attempts - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp wait_for_tcp_closed(port, attempts \\ 20)
  defp wait_for_tcp_closed(_port, 0), do: {:error, :still_open}

  defp wait_for_tcp_closed(port, attempts) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 100) do
      {:error, :econnrefused} ->
        {:error, :econnrefused}

      {:ok, socket} ->
        :gen_tcp.close(socket)
        Process.sleep(50)
        wait_for_tcp_closed(port, attempts - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stop_daemon(daemon, previous_host_key, previous_port) do
    if Process.alive?(daemon), do: GenServer.stop(daemon, :normal, @timeout)
    Application.put_env(:biot_server, :ssh_host_key_file, previous_host_key)
    Application.put_env(:biot_server, :ssh_port, previous_port)
  end
end
