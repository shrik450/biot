defmodule BiotWeb.PreviewProxyIntegrationTest do
  use BiotWeb.ConnCase, async: false

  alias Biot.Protocol.{Hostname, PrincipalId}
  alias Biot.Server.{Access, AccessHarness, Credentials, Repo, Sessions}
  alias Biot.Server.Credentials.Created
  alias Biot.Server.Schema.{Publication, ViewGrant}
  alias Biot.Server.TestFixtures, as: ServerFixtures
  alias BiotWeb.Cookies
  alias BiotWeb.Endpoint
  alias BiotWeb.Preview.Failure
  alias BiotWeb.TestFixtures

  @timeout 5_000

  defmodule Upstream do
    @moduledoc false

    import Plug.Conn

    @spec init(keyword()) :: keyword()
    def init(options), do: options

    @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
    def call(conn, options) do
      {body, conn} = read_full_body(conn, <<>>)

      send(
        options[:owner],
        {:upstream_request, conn.method, conn.request_path, conn.req_headers, body}
      )

      if options[:close] do
        # An upstream that accepts the connection and closes it without writing a byte. Returning
        # an unsent conn would make Bandit answer 500 instead, and an `exit/1` is caught and
        # rendered the same way; an untrappable kill closes the socket. This branch never returns.
        Process.exit(self(), :kill)
      else
        conn =
          Enum.reduce(options[:headers] || [], conn, fn {name, value}, conn ->
            put_resp_header(conn, name, value)
          end)

        send_resp(conn, options[:status] || 200, options[:body] || "")
      end
    end

    defp read_full_body(conn, body) do
      case read_body(conn, length: 65_536, read_length: 65_536) do
        {:ok, chunk, conn} -> {body <> chunk, conn}
        {:more, chunk, conn} -> read_full_body(conn, body <> chunk)
      end
    end
  end

  setup_all do
    directory = Path.join(System.tmp_dir!(), "biot-preview-#{System.unique_integer([:positive])}")
    {:ok, certificates} = Biot.Server.TestFixtures.certificates(directory, 1)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{certificates: certificates}
  end

  setup %{certificates: certificates} do
    listener_port = AccessHarness.start_listener(certificates)
    node = AccessHarness.node_row(1, certificates, 0)
    owner = TestFixtures.principal(1)
    viewer = TestFixtures.principal(2)
    stranger = TestFixtures.principal(3)
    {biot, _environment} = TestFixtures.biot(owner, node, 1)
    port = TestFixtures.port(3_000)
    {:ok, hostname} = Hostname.parse("proxy-preview")

    Repo.insert!(%Publication{biot_id: biot.id, port: port, hostname: hostname, state: :active})
    Repo.insert!(%ViewGrant{biot_id: biot.id, port: port, principal_id: viewer.id})
    ServerFixtures.observation(biot, 1, container: ServerFixtures.running_container(1))
    peer = AccessHarness.ready_peer(listener_port, certificates, node, 0)

    on_exit(fn -> :ssl.close(peer.socket) end)

    {:ok, viewer_control} = Sessions.start_control(viewer.id)
    {:ok, viewer_auth} = Sessions.control(viewer_control)

    {:ok, %Created{token: viewer_credential}} =
      Credentials.create(viewer_auth, "viewer", DateTime.add(DateTime.utc_now(), 3_600, :second))

    {:ok, stranger_control} = Sessions.start_control(stranger.id)
    {:ok, stranger_auth} = Sessions.control(stranger_control)

    {:ok, %Created{token: stranger_credential}} =
      Credentials.create(
        stranger_auth,
        "stranger",
        DateTime.add(DateTime.utc_now(), 3_600, :second)
      )

    %{
      certificates: certificates,
      peer: peer,
      owner: owner,
      viewer: viewer,
      stranger: stranger,
      viewer_credential: viewer_credential,
      stranger_credential: stranger_credential,
      biot: biot,
      port: port,
      hostname: hostname
    }
  end

  test "a published hostname reaches the real upstream with a streamed body", context do
    body = String.duplicate("preview-body-", 20_000)
    {:ok, upstream, upstream_port} = start_upstream(self(), body: body)
    {:ok, proxy, proxy_port} = start_proxy()

    on_exit(fn ->
      stop_bandit(proxy)
      stop_bandit(upstream)
    end)

    request_body = String.duplicate("request-body-", 8_000)

    client =
      Task.async(fn ->
        http_request(
          proxy_port,
          preview_host(context.hostname),
          "/large?mode=stream",
          [
            {"content-length", Integer.to_string(byte_size(request_body))},
            {"x-biot-authorization", "Bearer " <> context.viewer_credential},
            {"x-biot-principal-id", "forged"},
            {"x-biot-extra", "drop"},
            {"forwarded", "forged"},
            {"x-forwarded-for", "forged"},
            {"cookie", "app=kept; __Host-biot_preview=secret; __Host-biot_other=secret2"}
          ],
          request_body
        )
      end)

    open = AccessHarness.await_open(context.peer)
    attach = AccessHarness.attach(context.peer, open.stream_id)
    bridge(attach, upstream_port)
    response = Task.await(client, @timeout)

    assert response.status == 200
    assert response.body == body
    assert_receive {:upstream_request, "POST", "/large", headers, ^request_body}, @timeout

    assert header(headers, "x-biot-principal-id") ==
             PrincipalId.to_string(context.viewer.id)

    assert header(headers, "cookie") == "app=kept"
    refute header(headers, "x-biot-authorization")
    refute header(headers, "x-biot-extra")
    refute header(headers, "forwarded")
    assert header(headers, "x-forwarded-for") == "127.0.0.1"
    assert header(headers, "x-forwarded-proto") == "https"
    assert header(headers, "x-forwarded-host") == preview_host(context.hostname)
  end

  test "a chunked upstream response with trailers reaches the client intact", context do
    {:ok, proxy, proxy_port} = start_proxy()
    on_exit(fn -> stop_bandit(proxy) end)

    client =
      Task.async(fn ->
        http_request(proxy_port, preview_host(context.hostname), "/chunked", [
          {"x-biot-authorization", "Bearer " <> context.viewer_credential}
        ])
      end)

    open = AccessHarness.await_open(context.peer)
    attach = AccessHarness.attach(context.peer, open.stream_id)

    :ok =
      :ssl.send(
        attach,
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" <>
          "3\r\nabc\r\n2\r\nde\r\n0\r\nx-test: yes\r\n\r\n"
      )

    response = Task.await(client, @timeout)
    assert response.status == 200
    assert response.body == "abcde"
  end

  test "a request body exactly at the limit is forwarded", context do
    previous_max = Application.get_env(:biot_server, :preview_request_max_bytes)
    previous_chunk = Application.get_env(:biot_server, :preview_request_chunk_bytes)
    Application.put_env(:biot_server, :preview_request_max_bytes, 4)
    Application.put_env(:biot_server, :preview_request_chunk_bytes, 2)

    on_exit(fn ->
      Application.put_env(:biot_server, :preview_request_max_bytes, previous_max)
      Application.put_env(:biot_server, :preview_request_chunk_bytes, previous_chunk)
    end)

    {:ok, proxy, proxy_port} = start_proxy()
    on_exit(fn -> stop_bandit(proxy) end)

    client =
      Task.async(fn ->
        http_request(
          proxy_port,
          preview_host(context.hostname),
          "/exact",
          [
            {"content-length", "4"},
            {"x-biot-authorization", "Bearer " <> context.viewer_credential}
          ],
          "abcd"
        )
      end)

    open = AccessHarness.await_open(context.peer)
    attach = AccessHarness.attach(context.peer, open.stream_id)
    :ok = :ssl.send(attach, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")

    response = Task.await(client, @timeout)
    assert response.status == 200
    assert response.body == "ok"
    _ = :ssl.close(attach)
  end

  test "a request body one byte over the limit is refused after cumulative reads", context do
    previous_max = Application.get_env(:biot_server, :preview_request_max_bytes)
    previous_chunk = Application.get_env(:biot_server, :preview_request_chunk_bytes)
    Application.put_env(:biot_server, :preview_request_max_bytes, 4)
    Application.put_env(:biot_server, :preview_request_chunk_bytes, 2)

    on_exit(fn ->
      Application.put_env(:biot_server, :preview_request_max_bytes, previous_max)
      Application.put_env(:biot_server, :preview_request_chunk_bytes, previous_chunk)
    end)

    {:ok, proxy, proxy_port} = start_proxy()
    on_exit(fn -> stop_bandit(proxy) end)

    client =
      Task.async(fn ->
        http_request(
          proxy_port,
          preview_host(context.hostname),
          "/over",
          [
            {"content-length", "5"},
            {"x-biot-authorization", "Bearer " <> context.viewer_credential}
          ],
          "abcde"
        )
      end)

    open = AccessHarness.await_open(context.peer)
    attach = AccessHarness.attach(context.peer, open.stream_id)
    :ok = :ssl.send(attach, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")

    response = Task.await(client, @timeout)
    assert response.status == 413
    assert response.body =~ "Request too large"
    _ = :ssl.close(attach)
  end

  test "a person without a view grant gets 403 with a control-host link", context do
    {:ok, proxy, proxy_port} = start_proxy()
    on_exit(fn -> stop_bandit(proxy) end)

    response =
      http_request(proxy_port, preview_host(context.hostname), "/", [
        {"x-biot-authorization", "Bearer " <> context.stranger_credential}
      ])

    assert response.status == 403
    assert response.body =~ BiotWeb.Endpoint.url()
    assert response.body =~ "Open Biot"
  end

  test "valid credentials do not redirect and invalid credentials never fall back to cookies",
       context do
    {:ok, proxy, proxy_port} = start_proxy()
    on_exit(fn -> stop_bandit(proxy) end)

    valid =
      Task.async(fn ->
        http_request(proxy_port, preview_host(context.hostname), "/", [
          {"x-biot-authorization", "Bearer " <> context.viewer_credential}
        ])
      end)

    open = AccessHarness.await_open(context.peer)
    attach = AccessHarness.attach(context.peer, open.stream_id)
    :ok = :ssl.send(attach, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
    valid_response = Task.await(valid, @timeout)

    assert valid_response.status == 200
    assert valid_response.body == "ok"
    refute Map.has_key?(valid_response.headers, "location")
    refute Enum.any?(valid_response.set_cookie, &String.contains?(&1, "biot_"))

    invalid =
      http_request(proxy_port, preview_host(context.hostname), "/", [
        {"x-biot-authorization", "Bearer invalid"},
        {"cookie", Cookies.preview_name() <> "=would-be-fallback"}
      ])

    assert invalid.status == 401
    refute Map.has_key?(invalid.headers, "location")
    refute Enum.any?(invalid.set_cookie, &String.contains?(&1, "biot_"))
  end

  test "revoking a view grant closes an open WebSocket and denies the next request", context do
    {:ok, proxy, proxy_port} = start_proxy()
    on_exit(fn -> stop_bandit(proxy) end)

    client =
      Task.async(fn ->
        websocket_connect(
          proxy_port,
          preview_host(context.hostname),
          [
            {"x-biot-authorization", "Bearer " <> context.viewer_credential}
          ],
          nil
        )
      end)

    open = AccessHarness.await_open(context.peer)
    attach = AccessHarness.attach(context.peer, open.stream_id)
    {:ok, handshake} = :ssl.recv(attach, 0, @timeout)
    key = header(parse_head(handshake), "sec-websocket-key")
    accept = Base.encode64(:crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))

    :ok =
      :ssl.send(attach, [
        "HTTP/1.1 101 Switching Protocols\r\n",
        "Upgrade: websocket\r\nConnection: Upgrade\r\n",
        "Sec-WebSocket-Accept: ",
        accept,
        "\r\n\r\n"
      ])

    {:ok, socket} = Task.await(client, @timeout)

    assert {:ok, _} =
             Access.revoke_view(
               TestFixtures.actor(context.owner),
               context.biot.id,
               context.port,
               context.viewer.id
             )

    assert recv_ws(socket) in [{8, <<1008::unsigned-big-16, "policy-closed">>}, {:closed, <<>>}]
    assert AccessHarness.closed?(attach)

    AccessHarness.apply_access(context.peer, context.biot.id, 2)

    denied =
      http_request(proxy_port, preview_host(context.hostname), "/", [
        {"x-biot-authorization", "Bearer " <> context.viewer_credential}
      ])

    assert denied.status == 403
  end

  test "an incomplete upstream handshake at the exact limit keeps waiting for more bytes",
       context do
    previous_head_max = Application.get_env(:biot_server, :preview_head_max_bytes)
    Application.put_env(:biot_server, :preview_head_max_bytes, 34)

    on_exit(fn ->
      Application.put_env(:biot_server, :preview_head_max_bytes, previous_head_max)
    end)

    {:ok, proxy, proxy_port} = start_proxy()
    on_exit(fn -> stop_bandit(proxy) end)

    client =
      Task.async(fn ->
        {:ok, socket} =
          websocket_connect(
            proxy_port,
            preview_host(context.hostname),
            [
              {"x-biot-authorization", "Bearer " <> context.viewer_credential}
            ],
            nil
          )

        result = :gen_tcp.recv(socket, 0, @timeout)
        :gen_tcp.close(socket)
        result
      end)

    open = AccessHarness.await_open(context.peer)
    attach = AccessHarness.attach(context.peer, open.stream_id)
    assert {:ok, _handshake} = :ssl.recv(attach, 0, @timeout)
    :ok = :ssl.send(attach, "HTTP/1.1 101 Switching Protocols\r\n")

    assert Task.yield(client, 100) == nil

    :ok = :ssl.close(attach)
    result = Task.await(client, @timeout)
    assert match?({:error, :closed}, result) or match?({:ok, _data}, result)
  end

  test "upstream Biot cookies are stripped while ordinary cookies pass through", context do
    {:ok, upstream, upstream_port} =
      start_upstream(self(),
        body: "ok",
        headers: [
          {"set-cookie", "__Host-biot_preview=forged; Secure; Path=/"},
          {"set-cookie", "application=kept; Path=/"}
        ]
      )

    {:ok, proxy, proxy_port} = start_proxy()

    on_exit(fn ->
      stop_bandit(proxy)
      stop_bandit(upstream)
    end)

    client =
      Task.async(fn ->
        http_request(proxy_port, preview_host(context.hostname), "/", [
          {"x-biot-authorization", "Bearer " <> context.viewer_credential},
          {"cookie", "application=kept; __Host-biot_session=forged"}
        ])
      end)

    open = AccessHarness.await_open(context.peer)
    attach = AccessHarness.attach(context.peer, open.stream_id)
    bridge(attach, upstream_port)
    response = Task.await(client, @timeout)

    assert response.status == 200
    assert response.body == "ok"
    assert response.set_cookie == ["application=kept; Path=/"]
    assert_receive {:upstream_request, "POST", "/", headers, ""}, @timeout
    assert header(headers, "cookie") == "application=kept"
  end

  test "a sibling preview origin is refused before an upgrade", context do
    {:ok, proxy, proxy_port} = start_proxy()
    on_exit(fn -> stop_bandit(proxy) end)

    response =
      websocket_status(proxy_port, preview_host(context.hostname), [
        {"x-biot-authorization", "Bearer " <> context.viewer_credential},
        {"origin", "https://sibling.env.test"}
      ])

    assert response.status == 403
    AccessHarness.no_message(context.peer, Biot.Protocol.Message.OpenStream, 300)
  end

  test "an upstream that closes without answering is an invalid response, not a stopped Biot",
       context do
    {:ok, upstream, upstream_port} = start_upstream(self(), close: true)
    {:ok, proxy, proxy_port} = start_proxy()

    on_exit(fn ->
      stop_bandit(proxy)
      stop_bandit(upstream)
    end)

    client =
      Task.async(fn ->
        http_request(proxy_port, preview_host(context.hostname), "/", [
          {"x-biot-authorization", "Bearer " <> context.viewer_credential}
        ])
      end)

    open = AccessHarness.await_open(context.peer)
    attach = AccessHarness.attach(context.peer, open.stream_id)
    bridge(attach, upstream_port)

    response = Task.await(client, @timeout)

    # The application really was reached, so the close came from it and not from the node.
    assert_receive {:upstream_request, "POST", "/", _headers, ""}, @timeout

    assert response.status == 502
    assert response.body =~ "did not return a valid response"
    refute response.body =~ "Biot not running"
  end

  # The reasons come from the module, so a page added without a status here fails the assertion;
  # the statuses are the contract, so each one is written down.
  @failure_statuses %{
    not_found: 404,
    forbidden: 403,
    unauthenticated: 401,
    unsupported_credential: 401,
    node_unavailable: 503,
    agent_unreachable: 503,
    invalid_response: 502,
    port_not_listening: 502,
    too_large: 413,
    too_many_streams: 503,
    timeout: 503
  }

  test "failure pages expose the model status for every proxy failure" do
    assert Failure.reasons() == Enum.sort(Map.keys(@failure_statuses))

    for {reason, status} <- @failure_statuses do
      {actual, body} = Failure.response(reason, Endpoint.url())
      assert actual == status, inspect(reason)
      assert body =~ "<html", inspect(reason)
    end
  end

  defp start_upstream(owner, options) do
    {:ok, pid} =
      Bandit.start_link(
        plug: {Upstream, Keyword.put(options, :owner, owner)},
        scheme: :http,
        port: 0,
        startup_log: false
      )

    Process.unlink(pid)
    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    {:ok, pid, port}
  end

  defp start_proxy do
    {:ok, pid} =
      Bandit.start_link(plug: BiotWeb.Endpoint, scheme: :http, port: 0, startup_log: false)

    Process.unlink(pid)
    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    {:ok, pid, port}
  end

  defp stop_bandit(pid), do: if(Process.alive?(pid), do: Supervisor.stop(pid, :normal, @timeout))

  defp preview_host(hostname),
    do:
      Hostname.to_string(hostname) <>
        "." <> Application.fetch_env!(:biot_server, :publication_domain)

  defp http_request(port, host, path, headers, body \\ "") do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], @timeout)

    request = [
      "POST ",
      path,
      " HTTP/1.1\r\nHost: ",
      host,
      "\r\n",
      Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      if(
        body != "" and
          not Enum.any?(headers, fn {name, _value} ->
            String.downcase(name) == "content-length"
          end),
        do: ["Content-Length: ", Integer.to_string(byte_size(body)), "\r\n"],
        else: []
      ),
      "Connection: close\r\n\r\n",
      body
    ]

    :ok = :gen_tcp.send(socket, request)
    response = recv_http(socket, <<>>)
    :gen_tcp.close(socket)
    response
  end

  defp websocket_connect(port, host, headers, _body) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], @timeout)
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    request = [
      "GET / HTTP/1.1\r\nHost: ",
      host,
      "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n",
      "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: ",
      key,
      "\r\n",
      Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "\r\n"
    ]

    :ok = :gen_tcp.send(socket, request)
    response = recv_headers_exact(socket, <<>>)

    if String.starts_with?(response, "HTTP/1.1 101"),
      do: {:ok, socket},
      else: raise(inspect(response))
  end

  defp websocket_status(port, host, headers) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], @timeout)
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    request = [
      "GET / HTTP/1.1\r\nHost: ",
      host,
      "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n",
      "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: ",
      key,
      "\r\n",
      Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "\r\n"
    ]

    :ok = :gen_tcp.send(socket, request)
    response = recv_headers_exact(socket, <<>>)
    :gen_tcp.close(socket)
    [_http, status | _rest] = String.split(response, " ", parts: 3)
    %{status: String.to_integer(status)}
  end

  defp bridge(attach, upstream_port) do
    {:ok, upstream} =
      :gen_tcp.connect(~c"127.0.0.1", upstream_port, [:binary, active: false], @timeout)

    to_upstream = Task.async(fn -> copy_ssl_to_tcp(attach, upstream) end)
    from_upstream = Task.async(fn -> copy_tcp_to_ssl(upstream, attach) end)
    _ = Task.await(from_upstream, @timeout)
    Task.shutdown(to_upstream, :brutal_kill)
    :gen_tcp.close(upstream)
  end

  defp copy_ssl_to_tcp(attach, upstream) do
    case :ssl.recv(attach, 0, @timeout) do
      {:ok, data} ->
        :gen_tcp.send(upstream, data)
        copy_ssl_to_tcp(attach, upstream)

      {:error, _reason} ->
        :gen_tcp.shutdown(upstream, :write)
    end
  end

  defp copy_tcp_to_ssl(upstream, attach) do
    case :gen_tcp.recv(upstream, 0, @timeout) do
      {:ok, data} ->
        :ssl.send(attach, data)
        copy_tcp_to_ssl(upstream, attach)

      {:error, _reason} ->
        :ssl.close(attach)
    end
  end

  defp recv_http(socket, buffer) do
    buffer = recv_until(socket, buffer, "\r\n\r\n")
    {head, rest} = split_head(buffer)
    {status, headers} = parse_response_head(head)
    {body, _tail} = recv_body(socket, rest, headers)

    %{
      status: status,
      headers: headers,
      body: body,
      set_cookie: Map.get(headers, "set-cookie", [])
    }
  end

  defp recv_until(socket, buffer, marker) do
    if :binary.match(buffer, marker) != :nomatch do
      buffer
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, @timeout)
      recv_until(socket, buffer <> data, marker)
    end
  end

  defp recv_headers_exact(socket, buffer) do
    if :binary.match(buffer, "\r\n\r\n") != :nomatch do
      buffer
    else
      {:ok, byte} = :gen_tcp.recv(socket, 1, @timeout)
      recv_headers_exact(socket, buffer <> byte)
    end
  end

  defp split_head(buffer) do
    {position, 4} = :binary.match(buffer, "\r\n\r\n")

    {binary_part(buffer, 0, position),
     binary_part(buffer, position + 4, byte_size(buffer) - position - 4)}
  end

  defp parse_response_head(head) do
    [status_line | lines] = String.split(head, "\r\n")
    [_, status | _] = String.split(status_line, " ", parts: 3)

    headers =
      Enum.reduce(lines, %{}, fn line, acc ->
        [name, value] = String.split(line, ": ", parts: 2)
        key = String.downcase(name)
        Map.update(acc, key, [value], &(&1 ++ [value]))
      end)

    {String.to_integer(status), headers}
  end

  defp recv_body(socket, buffer, headers) do
    if Enum.any?(
         Map.get(headers, "transfer-encoding", []),
         &String.contains?(String.downcase(&1), "chunked")
       ) do
      recv_chunked(socket, buffer, <<>>)
    else
      case Map.get(headers, "content-length") do
        [length] -> recv_exact(socket, buffer, String.to_integer(length), <<>>)
        _missing -> recv_to_close(socket, buffer)
      end
    end
  end

  defp recv_exact(_socket, buffer, length, body) when byte_size(buffer) >= length do
    {body <> binary_part(buffer, 0, length),
     binary_part(buffer, length, byte_size(buffer) - length)}
  end

  defp recv_exact(socket, buffer, length, body) do
    {:ok, data} = :gen_tcp.recv(socket, 0, @timeout)
    recv_exact(socket, buffer <> data, length, body)
  end

  defp recv_chunked(socket, buffer, body) do
    buffer = recv_until(socket, buffer, "\r\n")
    {line, rest} = split_line(buffer)
    {size, ""} = Integer.parse(line, 16)

    if size == 0 do
      {body, rest}
    else
      buffer = recv_until(socket, rest, "\r\n")

      {chunk, rest} =
        {binary_part(buffer, 0, size), binary_part(buffer, size, byte_size(buffer) - size)}

      <<"\r\n", rest::binary>> = rest
      recv_chunked(socket, rest, body <> chunk)
    end
  end

  defp split_line(buffer) do
    {position, 2} = :binary.match(buffer, "\r\n")

    {binary_part(buffer, 0, position),
     binary_part(buffer, position + 2, byte_size(buffer) - position - 2)}
  end

  defp recv_to_close(socket, buffer) do
    case :gen_tcp.recv(socket, 0, @timeout) do
      {:ok, data} -> recv_to_close(socket, buffer <> data)
      {:error, :closed} -> {buffer, <<>>}
    end
  end

  defp parse_head(bytes) do
    {head, _rest} = split_head(bytes)
    [_request_line | lines] = String.split(head, "\r\n")

    Enum.reduce(lines, %{}, fn line, acc ->
      [name, value] = String.split(line, ": ", parts: 2)
      Map.put(acc, String.downcase(name), [value])
    end)
  end

  defp header(headers, name) when is_map(headers),
    do: headers |> Map.get(String.downcase(name), []) |> List.first()

  defp header(headers, name) when is_list(headers) do
    name = String.downcase(name)

    Enum.find_value(headers, fn
      {^name, value} -> value
      _header -> nil
    end)
  end

  defp recv_ws(socket) do
    case :gen_tcp.recv(socket, 2, @timeout) do
      {:ok, <<_fin::1, _rsv::3, opcode::4, _masked::1, length::7>>} ->
        {:ok, payload} = :gen_tcp.recv(socket, length, @timeout)
        {opcode, payload}

      {:error, :closed} ->
        {:closed, <<>>}
    end
  end
end
