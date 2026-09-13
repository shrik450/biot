defmodule Biot.Node.StreamsFixture do
  @moduledoc false

  alias Biot.Node.Allocation
  alias Biot.Node.Host.Config
  alias Biot.Node.Host.Paths
  alias Biot.Node.Journal
  alias Biot.Node.NetworkId
  alias Biot.Node.NodePrivatePath
  alias Biot.Protocol.Certificates
  alias Biot.Protocol.Frame
  alias Biot.Protocol.Message
  alias Biot.Protocol.RegistrationId
  alias Biot.Protocol.Wire

  defmodule AgentHandle do
    @moduledoc false
    @enforce_keys [:port, :os_pid]
    defstruct [:port, :os_pid, :binary, :log]
  end

  @doc "A unique temporary directory under the system temp root."
  def temporary_directory(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  @doc """
  Points the host config at a fresh data root and a one-UID range that covers the test process.
  Restores every changed setting and removes the data root when the calling test module exits.
  """
  def put_host_config(prefix) do
    data_root = temporary_directory(prefix)

    settings = [
      data_root: data_root,
      uid_range_base: host_uid(),
      uid_range_count: 1,
      uid_range_limit: 65_536
    ]

    previous =
      Map.new(settings, fn {key, _value} -> {key, Application.fetch_env(:biot_node, key)} end)

    Enum.each(settings, fn {key, value} -> Application.put_env(:biot_node, key, value) end)

    ExUnit.Callbacks.on_exit(fn ->
      File.rm_rf!(data_root)

      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:biot_node, key, value)
        {key, :error} -> Application.delete_env(:biot_node, key)
      end)
    end)

    :ok
  end

  def certificates(directory), do: Certificates.generate(directory, 1)

  @doc "The host UID the test process runs as, which the seeded allocation must cover."
  def host_uid do
    {output, 0} = System.cmd("id", ["-u"])
    String.trim(output) |> String.to_integer()
  end

  @doc "Builds the real Go agent from the current source."
  def agent_binary do
    repo_root = Path.expand("../../../..", __DIR__)
    binary = Path.join(repo_root, ".work/biot-agent-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.dirname(binary))

    {output, status} =
      System.cmd("go", ["build", "-o", binary, "./cmd/biot-agent"],
        cd: Path.join(repo_root, "agent"),
        stderr_to_stdout: true
      )

    if status != 0, do: raise("go build failed:\n#{output}")
    binary
  end

  @doc "Seeds a journal allocation and run directory, and returns the agent socket path."
  def seed_allocation(biot_id, uid_range) do
    config = Config.from_application!()
    {:ok, data_path} = NodePrivatePath.parse(Paths.biot(config, biot_id))

    {:ok, _allocation} =
      Journal.put_allocation(%Allocation{
        biot_id: biot_id,
        uid_range: uid_range,
        data_root: data_path,
        network_id: NetworkId.from_biot_id(biot_id),
        initialization: :uninitialized
      })

    run = Paths.run(config, biot_id)
    File.mkdir_p!(run)
    Path.join(run, "agent.sock")
  end

  @doc "Starts the real agent as an OS process and waits for its socket."
  def start_agent(socket_path, entrypoint \\ "/bin/sh") do
    binary = agent_binary()
    repo_root = Path.expand("../../../..", __DIR__)
    log = Path.join(repo_root, ".work/biot-agent-#{System.unique_integer([:positive])}.log")
    File.mkdir_p!(Path.dirname(log))

    # The agent's output goes to a file rather than this process's stdout, so a leaked agent can
    # never hold a pipe open after the test process exits.
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        args: [
          "-c",
          ~s(exec "$0" --socket "$1" --shell-entrypoint "$2" >> "$3" 2>&1),
          binary,
          socket_path,
          entrypoint,
          log
        ]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    agent = %AgentHandle{port: port, os_pid: os_pid, binary: binary, log: log}
    ExUnit.Callbacks.on_exit(fn -> stop_agent(agent) end)
    wait_until(fn -> if File.exists?(socket_path), do: :ok end, "agent socket #{socket_path}")
    agent
  end

  def stop_agent(nil), do: :ok

  def stop_agent(%AgentHandle{port: port, os_pid: os_pid, binary: binary, log: log}) do
    _ = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)

    try do
      _ = Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    _ = remove_file(binary)
    _ = remove_file(log)
    :ok
  end

  def stop_agent(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> stop_agent(%AgentHandle{port: port, os_pid: os_pid})
      _other -> :ok
    end
  end

  defp remove_file(nil), do: :ok
  defp remove_file(path), do: File.rm(path)

  @doc "A real 127.0.0.1 echo service. Returns its port."
  def start_echo_service do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)

    spawn_link(fn ->
      loop_echo(listener)
    end)

    port
  end

  @doc """
  A real mutually-authenticated TLS listener that answers one node's `attach` and then serves the
  stream.

  `answer` is called with the accepted socket after the server has sent the framed `attached`
  message plus `extra` in one write, so bytes can ride the same segment as `attached`. It returns
  the bytes the peer sent back so the test can assert on them.
  """
  def start_attach_server(certificates, extra, answer) do
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

    task =
      Task.async(fn ->
        {:ok, transport} = :ssl.transport_accept(listener, 10_000)
        {:ok, socket} = :ssl.handshake(transport, 10_000)
        {:ok, _attach} = read_attach(socket, <<>>)

        {:ok, attached} = Wire.encode(%Message.Attached{}, :handshake)
        :ok = :ssl.send(socket, [Frame.encode(attached), extra])

        accepted = answer.(socket)
        _ = :ssl.close(socket)
        accepted
      end)

    {port, task, listener}
  end

  @doc "Reads one framed control frame, the node's `attach`."
  def read_attach_result(task), do: Task.await(task, 20_000)

  def registration_id, do: elem(RegistrationId.parse(Ecto.UUID.generate()), 1)

  def wait_until(fun, label, attempts \\ 300) do
    result =
      Enum.reduce_while(1..attempts, nil, fn _attempt, _acc ->
        case fun.() do
          nil ->
            Process.sleep(20)
            {:cont, nil}

          value ->
            {:halt, value}
        end
      end)

    if is_nil(result), do: raise("timed out waiting for #{label}")
    result
  end

  defp read_attach(socket, buffer) do
    case Frame.take(buffer, 1_000_000) do
      {:ok, frame, rest} ->
        {:ok, message} = Wire.decode(frame, :handshake)
        if match?(%Message.Attach{}, message), do: {:ok, message}, else: read_attach(socket, rest)

      :more ->
        {:ok, data} = :ssl.recv(socket, 0, 10_000)
        read_attach(socket, buffer <> data)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "A real Unix-socket peer that reads one request line and optionally answers it."
  def start_fake_agent(path, reply, parent, extra \\ "") do
    spawn_link(fn -> fake_agent(path, reply, extra, parent) end)
  end

  defp fake_agent(path, reply, extra, parent) do
    File.rm(path)
    {:ok, listen} = :socket.open(:local, :stream, %{})
    :ok = :socket.bind(listen, %{family: :local, path: path})
    :ok = :socket.listen(listen, 1)
    send(parent, {:listening, self()})

    {:ok, connection} = :socket.accept(listen)
    send(parent, {:accepted, self()})

    case read_line(connection, <<>>, 0) do
      {:ok, line} ->
        send(parent, {:request, line})
        if reply, do: :socket.send(connection, [reply, "\n", extra])

      {:error, reason} ->
        send(parent, {:no_request, reason})
    end

    Process.sleep(1_000)
    _ = :socket.close(connection)
    _ = :socket.close(listen)
    :ok
  end

  defp read_line(_connection, _buffer, received) when received > 16 * 1024,
    do: {:error, :too_large}

  defp read_line(connection, buffer, received) do
    case :binary.match(buffer, "\n") do
      {index, 1} ->
        {:ok, binary_part(buffer, 0, index)}

      :nomatch ->
        case :socket.recv(connection, 0, 2_000) do
          {:ok, data} -> read_line(connection, buffer <> data, received + byte_size(data))
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp loop_echo(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        spawn_link(fn -> echo(socket) end)
        loop_echo(listener)

      {:error, _reason} ->
        :ok
    end
  end

  defp echo(socket) do
    case :gen_tcp.recv(socket, 0, 20_000) do
      {:ok, data} ->
        :ok = :gen_tcp.send(socket, data)
        echo(socket)

      {:error, _reason} ->
        :ok
    end
  end
end
