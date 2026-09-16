defmodule BiotWeb.TerminalTransportIntegrationTest do
  use BiotWeb.ConnCase, async: false

  import Bitwise, only: [bor: 2, bxor: 2]

  alias Biot.Protocol.{Hostname, ShellFrame}
  alias Biot.Server.Access
  alias Biot.Server.AccessHarness
  alias Biot.Server.Repo
  alias Biot.Server.Schema.{Publication, ShellGrant, ViewGrant}
  alias Biot.Server.Sessions
  alias Biot.Server.TestFixtures, as: ServerFixtures
  alias BiotWeb.Cookies
  alias BiotWeb.TestFixtures

  @timeout 5_000

  setup_all do
    directory =
      Path.join(System.tmp_dir!(), "biot-terminal-#{System.unique_integer([:positive])}")

    {:ok, certificates} = Biot.Server.TestFixtures.certificates(directory, 1)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{certificates: certificates}
  end

  setup %{certificates: certificates} do
    listener_port = AccessHarness.start_listener(certificates)
    node = AccessHarness.node_row(1, certificates, 0)
    owner = TestFixtures.principal(1)
    collaborator = TestFixtures.principal(2)
    viewer = TestFixtures.principal(3)
    {biot, _environment} = TestFixtures.biot(owner, node, 1)
    Repo.insert!(%ShellGrant{biot_id: biot.id, principal_id: collaborator.id})
    port = TestFixtures.port(3000)
    {:ok, hostname} = Hostname.parse("terminal-preview")
    Repo.insert!(%Publication{biot_id: biot.id, port: port, hostname: hostname, state: :active})
    Repo.insert!(%ViewGrant{biot_id: biot.id, port: port, principal_id: viewer.id})
    ServerFixtures.observation(biot, 1, container: ServerFixtures.running_container(1))
    peer = AccessHarness.ready_peer(listener_port, certificates, node, 0)

    on_exit(fn -> :ssl.close(peer.socket) end)

    %{
      certificates: certificates,
      peer: peer,
      owner: owner,
      collaborator: collaborator,
      viewer: viewer,
      biot: biot
    }
  end

  test "Bandit admits an exact-origin control session and relays shell frames", context do
    {:ok, token} = Sessions.start_control(context.collaborator.id)
    cookie = session_cookie(token)
    {:ok, bandit, port} = start_bandit()
    on_exit(fn -> stop_bandit(bandit) end)

    owner = self()

    task =
      Task.async(fn ->
        websocket_connect(port, context.biot.id, cookie, BiotWeb.Endpoint.url(), owner)
      end)

    open = AccessHarness.await_open(context.peer)
    attach = AccessHarness.attach(context.peer, open.stream_id)
    {:ok, socket} = Task.await(task, @timeout)

    send_ws(socket, 2, "input")
    assert {:ok, [data_frame], <<>>} = recv_shell(attach)
    assert data_frame == {:data, "input"}

    send_ws(socket, 1, ~s({"resize":{"cols":120,"rows":40}}))
    assert {:ok, [resize_frame], <<>>} = recv_shell(attach)
    assert resize_frame == {:resize, 120, 40}

    {:ok, output} = ShellFrame.encode({:data, "welcome"})
    :ok = :ssl.send(attach, output)
    assert {2, "welcome"} == recv_ws(socket)

    {:ok, exit_frame} = ShellFrame.encode({:exit, 0})
    :ok = :ssl.send(attach, exit_frame)
    assert {1, ~s({"exit":0})} == recv_ws(socket)
    assert {8, _payload} = recv_ws(socket)
  end

  test "Bandit rejects missing credentials and foreign origins before upgrade", context do
    {:ok, bandit, port} = start_bandit()
    on_exit(fn -> stop_bandit(bandit) end)

    assert 401 = websocket_status(port, context.biot.id, nil, BiotWeb.Endpoint.url())

    assert 401 =
             websocket_status(port, context.biot.id, "not-a-valid-cookie", BiotWeb.Endpoint.url())

    assert 403 = websocket_status(port, context.biot.id, nil, "https://foreign.example")
  end

  test "a view-only collaborator is refused before WebSocket upgrade", context do
    {:ok, token} = Sessions.start_control(context.viewer.id)
    cookie = session_cookie(token)
    {:ok, bandit, port} = start_bandit()
    on_exit(fn -> stop_bandit(bandit) end)

    owner = self()

    task =
      Task.async(fn ->
        websocket_connect(port, context.biot.id, cookie, BiotWeb.Endpoint.url(), owner)
      end)

    {:ok, socket} = Task.await(task, @timeout)
    assert {8, <<1008::unsigned-big-16, "policy-closed">>} = recv_ws(socket)
  end

  test "revoking shell access closes an admitted WebSocket with policy code", context do
    {:ok, token} = Sessions.start_control(context.collaborator.id)
    cookie = session_cookie(token)
    {:ok, bandit, port} = start_bandit()
    on_exit(fn -> stop_bandit(bandit) end)

    owner = self()

    task =
      Task.async(fn ->
        websocket_connect(port, context.biot.id, cookie, BiotWeb.Endpoint.url(), owner)
      end)

    open = AccessHarness.await_open(context.peer)
    attach = AccessHarness.attach(context.peer, open.stream_id)
    {:ok, socket} = Task.await(task, @timeout)

    assert {:ok, _result} =
             Access.revoke_shell(
               TestFixtures.actor(context.owner),
               context.biot.id,
               context.collaborator.id
             )

    assert {8, <<1008::unsigned-big-16, "policy-closed">>} = recv_ws(socket)
    assert AccessHarness.closed?(attach)
  end

  defp start_bandit do
    {:ok, pid} =
      Bandit.start_link(plug: BiotWeb.Endpoint, scheme: :http, port: 0, startup_log: :error)

    Process.unlink(pid)
    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    {:ok, pid, port}
  end

  defp stop_bandit(pid) do
    if Process.alive?(pid), do: Supervisor.stop(pid, :normal, @timeout)
  end

  defp session_cookie(token) do
    response =
      Plug.Test.init_test_session(build_conn(), %{"token" => token})
      |> get("/login?return=/biots")

    BiotWeb.ConnCase.cookie_value(response, Cookies.session_name())
  end

  defp websocket_connect(port, biot_id, cookie, origin, owner) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], @timeout)
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    request = [
      "GET /biots/",
      to_string(biot_id),
      "/terminal/socket?term=xterm-256color&cols=80&rows=24 HTTP/1.1\r\n",
      "Host: localhost:",
      Integer.to_string(port),
      "\r\n",
      "Origin: ",
      origin,
      "\r\n",
      "Upgrade: websocket\r\n",
      "Connection: Upgrade\r\n",
      "Sec-WebSocket-Version: 13\r\n",
      "Sec-WebSocket-Key: ",
      key,
      "\r\n",
      if(cookie, do: ["Cookie: ", Cookies.session_name(), "=", cookie, "\r\n"], else: []),
      "\r\n"
    ]

    :ok = :gen_tcp.send(socket, request)
    {:ok, response} = :gen_tcp.recv(socket, 0, @timeout)

    if not String.starts_with?(response, "HTTP/1.1 101") do
      raise "websocket upgrade failed: #{inspect(response)}"
    end

    :ok = :gen_tcp.controlling_process(socket, owner)
    {:ok, socket}
  end

  defp websocket_status(port, biot_id, cookie, origin) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], @timeout)
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    request = [
      "GET /biots/",
      to_string(biot_id),
      "/terminal/socket?term=xterm&cols=80&rows=24 HTTP/1.1\r\n",
      "Host: localhost:",
      Integer.to_string(port),
      "\r\n",
      "Origin: ",
      origin,
      "\r\n",
      "Upgrade: websocket\r\nConnection: Upgrade\r\n",
      "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: ",
      key,
      "\r\n",
      if(cookie, do: ["Cookie: ", Cookies.session_name(), "=", cookie, "\r\n"], else: []),
      "\r\n"
    ]

    :ok = :gen_tcp.send(socket, request)
    {:ok, response} = :gen_tcp.recv(socket, 0, @timeout)
    :gen_tcp.close(socket)
    [_http, status | _] = String.split(response, " ", parts: 3)
    String.to_integer(status)
  end

  defp send_ws(socket, opcode, payload) do
    bytes = IO.iodata_to_binary(payload)
    mask = <<1, 2, 3, 4>>

    masked =
      bytes
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Enum.map(fn {byte, index} -> bxor(byte, :binary.at(mask, rem(index, 4))) end)

    frame =
      <<bor(0x80, opcode)::8, bor(0x80, byte_size(bytes))::8, mask::binary,
        :erlang.list_to_binary(masked)::binary>>

    :ok = :gen_tcp.send(socket, frame)
  end

  defp recv_ws(socket) do
    {:ok, <<_fin::1, _rsv::3, opcode::4, _masked::1, length::7>>} =
      :gen_tcp.recv(socket, 2, @timeout)

    {:ok, payload} = :gen_tcp.recv(socket, length, @timeout)
    {opcode, payload}
  end

  defp recv_shell(socket) do
    {:ok, <<type, length::unsigned-big-32>>} = :ssl.recv(socket, 5, @timeout)
    {:ok, payload} = :ssl.recv(socket, length, @timeout)
    ShellFrame.decode(<<type, length::unsigned-big-32, payload::binary>>, :to_agent)
  end
end
