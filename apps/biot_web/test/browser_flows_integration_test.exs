defmodule BiotWeb.BrowserFlowsIntegrationTest do
  use BiotWeb.ConnCase, async: false
  use Wallaby.DSL

  import Ecto.Query
  import Wallaby.Query

  alias Biot.Protocol.{ExecutionReport, Frame, Hostname, Message, Wire}
  alias Biot.Protocol.ShellFrame
  alias BiotWeb.OidcPeer
  alias BiotWeb.TestFixtures
  alias Elixir.Biot.Server.{AccessHarness, CommitEffects, Credentials, Repo, Sessions}
  alias Elixir.Biot.Server.Credentials.Created
  alias Elixir.Biot.Server.Schema.{Biot, ShellGrant}
  alias Elixir.Biot.Server.TestFixtures, as: ServerFixtures

  @endpoint_port 4002
  @timeout 10_000

  setup_all do
    capabilities = Application.fetch_env!(:wallaby, :chromedriver)[:capabilities]

    assert "--host-resolver-rules=MAP *.env.test 127.0.0.1" in get_in(capabilities, [
             :chromeOptions,
             :args
           ])

    directory =
      Path.join(System.tmp_dir!(), "biot-browser-#{System.unique_integer([:positive])}")

    {:ok, certificates} = ServerFixtures.certificates(directory, 1)

    {:ok, endpoint} =
      Bandit.start_link(plug: BiotWeb.Endpoint, scheme: :http, port: @endpoint_port)

    Process.unlink(endpoint)

    on_exit(fn ->
      if Process.alive?(endpoint), do: Supervisor.stop(endpoint, :normal, @timeout)
      File.rm_rf!(directory)
    end)

    %{certificates: certificates, endpoint: endpoint}
  end

  setup %{certificates: certificates} do
    peer = start_supervised!({OidcPeer, []})
    settings = OidcPeer.configuration(peer, "http://localhost:#{@endpoint_port}/login/callback")
    previous_oidc = Application.get_env(:biot_server, :oidc)
    Application.put_env(:biot_server, :oidc, settings)

    start_supervised!(
      {Oidcc.ProviderConfiguration.Worker,
       %{
         issuer: settings.issuer,
         name: Elixir.Biot.Server.Login.Provider,
         backoff_type: :random_exponential,
         backoff_min: 10,
         backoff_max: 100,
         provider_configuration_opts: %{quirks: %{allow_unsafe_http: true}}
       }}
    )

    assert provider_ready?()

    owner =
      TestFixtures.principal(1,
        issuer: settings.issuer,
        subject: "biot-test-subject",
        email: "user@example.test",
        name: "Test User"
      )

    stranger = TestFixtures.principal(3)

    listener_port = AccessHarness.start_listener(certificates)
    node = AccessHarness.node_row(1, certificates, 0)
    previous_default_node = Application.get_env(:biot_server, :default_node_id)
    Application.put_env(:biot_server, :default_node_id, node.id)
    {biot, _environment} = TestFixtures.biot(owner, node, 1)
    {:ok, hostname} = Hostname.parse("browser-preview")
    publication = AccessHarness.publication(biot, TestFixtures.port(3_000), hostname)
    Repo.insert!(%ShellGrant{biot_id: biot.id, principal_id: owner.id})
    ServerFixtures.observation(biot, 1, container: ServerFixtures.running_container(1))
    peer_connection = AccessHarness.ready_peer(listener_port, certificates, node, 0)

    {:ok, session} = Wallaby.start_session()

    on_exit(fn ->
      Wallaby.end_session(session)
      :ssl.close(peer_connection.socket)
      Application.put_env(:biot_server, :oidc, previous_oidc)
      Application.put_env(:biot_server, :default_node_id, previous_default_node)
    end)

    %{
      session: session,
      biot: biot,
      owner: owner,
      stranger: stranger,
      hostname: hostname,
      publication: publication,
      peer: peer_connection
    }
  end

  test "a person can sign in, see the Biot list, and open its overview", context do
    context.session
    |> visit("/login?return=/biots")
    |> assert_has(css("h1", text: "biots"))
    |> assert_has(css(".biot-name", text: "biot-1"))
    |> click(css("a.biot-row-target"))
    |> assert_has(css("h1", text: "biot-1"))
    |> assert_has(css("#desired-heading"))
  end

  test "a detail page updates quietly when the server state changes", context do
    session =
      context.session
      |> visit("/login?return=/biots/#{context.biot.id}")
      |> assert_has(css(".desired-marker", count: 2, text: "running"))

    Repo.update_all(
      from(biot in Biot, where: biot.id == ^context.biot.id),
      set: [desired_state: :stopped, desired_revision: 2]
    )

    assert :ok =
             CommitEffects.enforce(%CommitEffects{
               owners: [],
               wakes: [],
               readers: [context.biot.id]
             })

    session
    |> assert_has(css(".desired-marker", count: 2, text: "stopped"))
    |> assert_has(css("[aria-labelledby='desired-heading'] dd", text: "2"))
    |> refute_has(css(".inline-notice"))
  end

  test "the browser terminal accepts a command and renders the node output", context do
    session =
      context.session
      |> visit("/login?return=/biots/#{context.biot.id}/terminal")
      |> assert_has(css("#biot-terminal"))

    open = AccessHarness.await_open(context.peer)
    attach = AccessHarness.attach(context.peer, open.stream_id)

    session
    |> assert_has(css("#terminal-status", text: "connected"))
    |> click(css("#biot-terminal"))
    |> send_keys(["echo browser", :enter])

    session
    |> assert_has(css("#biot-terminal canvas"))
    |> execute_script(
      "return document.querySelector('#biot-terminal canvas').toDataURL()",
      fn value ->
        send(self(), {:terminal_canvas_before, value})
      end
    )

    assert {:data, command} = await_agent_data(attach, "echo browser")
    assert command =~ "echo browser"
    {:ok, output} = ShellFrame.encode({:data, "browser output\r\n"})
    :ok = :ssl.send(attach, output)

    session
    |> assert_has(css("#biot-terminal canvas"))
    |> execute_script(
      "return document.querySelector('#biot-terminal canvas').toDataURL()",
      fn value ->
        assert_receive {:terminal_canvas_before, before}, @timeout
        assert is_binary(value)
        refute value == before
      end
    )
  end

  test "creating without deliveries navigates to the stopped Biot", context do
    session =
      context.session
      |> visit("/login?return=/biots/new")
      |> fill_in(css("#biot-repository"), with: "https://example.test/browser.git")
      |> fill_in(css("#biot-name"), with: "browser-created")
      |> click(css("input[name='initial_state'][value='stopped']"))
      |> click(css("button.form-submit"))

    session = assert_has(session, css("h1", text: "browser-created"))

    assert Wallaby.Browser.current_url(session) =~
             ~r|\Ahttp://localhost:#{@endpoint_port}/biots/[0-9a-f-]+\z|
  end

  test "creating with a runtime secret shows the workflow before its detail page", context do
    session =
      context.session
      |> visit("/login?return=/biots/new")
      |> fill_in(css("#biot-repository"), with: "https://example.test/browser-secret.git")
      |> fill_in(css("#biot-name"), with: "browser-secret")
      |> click(css("input[name='initial_state'][value='stopped']"))
      |> fill_in(css("#secret-name-0"), with: "API_TOKEN")
      |> fill_in(css("input[name='runtime_secrets[0][value]']"), with: "secret-value")
      |> click(css("button.form-submit"))
      |> assert_has(css(".workflow-notice", text: "creating biot"))

    desired = AccessHarness.await_message(context.peer, Message.Desired)
    spec = desired.biot_spec

    send_observation(context.peer, spec.execution.biot_id, %ExecutionReport{
      accepted_revision: spec.execution.desired.revision,
      installed_environment_id: nil,
      container: ServerFixtures.running_container(4),
      data: :present,
      waiting_for: nil,
      failure: nil
    })

    send_observation(context.peer, spec.execution.biot_id, %ExecutionReport{
      accepted_revision: spec.execution.desired.revision,
      installed_environment_id: spec.execution.desired.environment_id,
      container: ServerFixtures.running_container(4),
      data: :present,
      waiting_for: nil,
      failure: nil
    })

    %Message.DeliverSecret{request_id: request_id} =
      AccessHarness.await_message(context.peer, Message.DeliverSecret, @timeout)

    send_peer_message(context.peer, %Message.SecretResult{request_id: request_id, result: :ok})

    session
    |> assert_has(css(".workflow-notice", text: "creating biot"))
    |> click(css("a", text: "open biot"))
    |> assert_has(css("h1", text: "browser-secret"))
  end

  test "a published URL renders the application in the browser", context do
    preview_url = preview_url(context.hostname)
    token = credential_token(context.owner)
    session = set_preview_credential(context.session, token)

    browser = Task.async(fn -> visit(session, preview_url) end)
    open = AccessHarness.await_open(context.peer)
    attach = AccessHarness.attach(context.peer, open.stream_id)

    body = "<html><body><main id=\"published-app\">application from the Biot</main></body></html>"

    :ok =
      :ssl.send(attach, [
        "HTTP/1.1 200 OK\r\n",
        "Content-Type: text/html\r\n",
        "Content-Length: ",
        Integer.to_string(byte_size(body)),
        "\r\nConnection: close\r\n\r\n",
        body
      ])

    session = Task.await(browser, @timeout)

    session
    |> assert_has(css("#published-app", text: "application from the Biot"))
  end

  test "a person without a view grant sees the preview access page", context do
    preview_url = preview_url(context.hostname)
    token = credential_token(context.stranger)

    context.session
    |> set_preview_credential(token)
    |> visit(preview_url)
    |> assert_has(css("h1", text: "No access"))
    |> assert_has(css("a", text: "Open Biot"))

    AccessHarness.no_message(context.peer, Message.OpenStream, 300)
  end

  defp provider_ready?(attempts \\ 100)
  defp provider_ready?(0), do: false

  defp provider_ready?(attempts) do
    case {:ets.lookup(Elixir.Biot.Server.Login.Provider, :provider_configuration),
          :ets.lookup(Elixir.Biot.Server.Login.Provider, :jwks)} do
      {[{_, _}], [{_, _}]} ->
        true

      _ ->
        Process.sleep(20)
        provider_ready?(attempts - 1)
    end
  end

  defp await_agent_data(socket, target, received \\ "") do
    {:ok, <<type, length::unsigned-big-32>>} = :ssl.recv(socket, 5, @timeout)
    {:ok, payload} = :ssl.recv(socket, length, @timeout)

    {:ok, [frame], <<>>} =
      ShellFrame.decode(<<type, length::unsigned-big-32, payload::binary>>, :to_agent)

    case frame do
      {:data, data} ->
        received = received <> data

        if String.contains?(received, target),
          do: {:data, received},
          else: await_agent_data(socket, target, received)

      _other ->
        await_agent_data(socket, target, received)
    end
  end

  defp send_observation(peer, biot_id, report) do
    {:ok, encoded} =
      Wire.encode(%Message.Observation{biot_id: biot_id, execution_report: report}, 1)

    :ok = :ssl.send(peer.socket, Frame.encode(encoded))
  end

  defp send_peer_message(peer, message) do
    {:ok, encoded} = Wire.encode(message, 1)
    :ok = :ssl.send(peer.socket, Frame.encode(encoded))
  end

  defp preview_url(hostname),
    do: "http://#{Hostname.to_string(hostname)}.env.test:#{@endpoint_port}"

  defp credential_token(principal) do
    {:ok, control_token} = Sessions.start_control(principal.id)
    {:ok, authentication} = Sessions.control(control_token)

    {:ok, %Created{token: token}} =
      Credentials.create(
        authentication,
        "browser-preview",
        DateTime.add(DateTime.utc_now(), 3600, :second)
      )

    token
  end

  defp set_preview_credential(session, token) do
    {:ok, _enable_response} =
      Wallaby.HTTPClient.request(
        :post,
        session.session_url <> "/chromium/send_command_and_get_result",
        %{cmd: "Network.enable", params: %{}}
      )

    {:ok, response} =
      Wallaby.HTTPClient.request(
        :post,
        session.session_url <> "/chromium/send_command_and_get_result",
        %{
          cmd: "Network.setExtraHTTPHeaders",
          params: %{headers: %{"X-Biot-Authorization" => "Bearer " <> token}}
        }
      )

    assert response["status"] == 0

    session
  end
end
