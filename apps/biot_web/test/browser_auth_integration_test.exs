defmodule BiotWeb.BrowserAuthIntegrationTest do
  use BiotWeb.ConnCase, async: false

  alias Biot.Protocol.{Hostname, SameOriginPath}
  alias Biot.Server.Credentials
  alias Biot.Server.Credentials.Created
  alias Biot.Server.PreviewHandoff
  alias Biot.Server.Repo
  alias Biot.Server.Schema.Publication
  alias Biot.Server.Sessions
  alias Biot.Server.Tokens
  alias BiotWeb.Plugs.ControlOrigin
  alias BiotWeb.TestFixtures

  setup do
    principal = TestFixtures.principal(1)
    other_principal = TestFixtures.principal(2)
    node = TestFixtures.node(1)
    {biot, _environment} = TestFixtures.biot(principal, node, 1)
    {:ok, control_token} = Sessions.start_control(principal.id)

    on_exit(fn -> Plug.CSRFProtection.delete_csrf_token() end)

    %{
      principal: principal,
      other_principal: other_principal,
      biot: biot,
      control_token: control_token,
      hostname: hostname("browser-preview")
    }
  end

  test "the origin rule permits safe and same-origin requests only", _context do
    for method <- ["GET", "HEAD", "OPTIONS"] do
      assert ControlOrigin.allowed?(
               method,
               ["https://foreign.example"],
               "https://control.example"
             )
    end

    assert ControlOrigin.allowed?("POST", [], "https://control.example")
    assert ControlOrigin.allowed?("POST", ["https://control.example"], "https://control.example")
    refute ControlOrigin.allowed?("POST", ["https://foreign.example"], "https://control.example")

    refute ControlOrigin.allowed?(
             "POST",
             ["https://control.example", "https://foreign.example"],
             "https://control.example"
           )
  end

  test "the LiveView socket accepts only the exact control origin", _context do
    control = URI.parse(BiotWeb.Endpoint.url())

    assert ControlOrigin.socket_origin?(control)
    refute ControlOrigin.socket_origin?(%{control | scheme: "https", port: 443})
    refute ControlOrigin.socket_origin?(%{control | port: control.port + 1})
    refute ControlOrigin.socket_origin?(%{control | host: "preview." <> control.host})
  end

  test "the control session cookie has the scoped lifetime and attributes", context do
    conn = browser_session(context.control_token)
    response = get(conn, "/login?return=/biots")
    assert response.status == 302
    assert get_resp_header(response, "location") == ["/biots"]

    cookie =
      Enum.find(
        get_resp_header(response, "set-cookie"),
        &String.starts_with?(&1, "__Host-biot_session=")
      )

    assert cookie =~ "__Host-biot_session="
    assert cookie =~ "secure"
    assert cookie =~ "HttpOnly"
    assert cookie =~ "SameSite=Lax"
    assert cookie =~ "path=/"
    refute cookie =~ "domain="
    assert cookie =~ "max-age=604800"
  end

  test "browser POSTs require CSRF and reject foreign origins", context do
    assert_error_sent 403, fn -> post(browser_session(context.control_token), "/logout", %{}) end

    {csrf, state} = csrf_state()

    assert_error_sent 403, fn ->
      browser_session(context.control_token, state)
      |> put_req_header("origin", "https://foreign.example")
      |> post("/logout", %{"_csrf_token" => csrf})
    end
  end

  test "logout needs a valid CSRF token and ends only its login tree", context do
    {:ok, control_authentication} = Sessions.control(context.control_token)
    {:ok, challenge_path} = SameOriginPath.parse("/preview")
    challenge = "handoff-challenge"

    Repo.insert!(%Publication{
      biot_id: context.biot.id,
      port: TestFixtures.port(3000),
      hostname: context.hostname,
      state: :active
    })

    {:ok, code} =
      PreviewHandoff.begin(
        control_authentication,
        context.hostname,
        Tokens.digest(challenge),
        challenge_path
      )

    {:ok, %PreviewHandoff.Finished{token: preview_token}} =
      PreviewHandoff.finish(context.hostname, code, challenge)

    {:ok, other_control_token} = Sessions.start_control(context.other_principal.id)
    {:ok, other_authentication} = Sessions.control(other_control_token)

    {:ok, %Created{token: credential_token}} =
      Credentials.create(
        other_authentication,
        "other-login",
        DateTime.add(DateTime.utc_now(), 86_400, :second)
      )

    {csrf, state} = csrf_state()

    response =
      browser_session(context.control_token, state)
      |> put_req_header("origin", BiotWeb.Endpoint.url())
      |> post("/logout", %{"_csrf_token" => csrf})

    assert response.status == 302
    assert get_resp_header(response, "location") == ["/"]
    assert Sessions.control(context.control_token) == :error
    assert Sessions.preview(context.hostname, preview_token) == :error
    assert other_control_token != context.control_token
    assert {:ok, _} = Sessions.control(other_control_token)
    assert {:ok, _} = Credentials.authenticate(credential_token)
  end

  test "a dead control token is removed from the browser session", _context do
    conn = browser_session("dead-token")
    response = get(conn, "/login")

    assert response.status == 503
    assert Plug.Conn.get_session(response, "token") == nil
  end

  test "the endpoint does not expose bearer credentials through browser auth", context do
    {:ok, control_authentication} = Sessions.control(context.control_token)

    {:ok, %Created{token: token, credential: credential}} =
      Credentials.create(
        control_authentication,
        "shown-once",
        DateTime.add(DateTime.utc_now(), 86_400, :second)
      )

    response = get(BiotWeb.ConnCase.api_conn(token), "/api/credentials")
    body = BiotWeb.ConnCase.json_body(response)

    assert response.status == 200
    assert Enum.any?(body, &(&1["id"] == to_string(credential.id)))
    refute Jason.encode!(body) =~ token
  end

  defp browser_session(token, csrf_state \\ nil) do
    session = %{"token" => token} |> maybe_put_csrf(csrf_state)

    conn = build_conn()
    conn = %{conn | private: Map.delete(conn.private, :plug_skip_csrf_protection)}
    Plug.Test.init_test_session(conn, session)
  end

  defp csrf_state do
    masked = Plug.CSRFProtection.get_csrf_token()
    {masked, Plug.CSRFProtection.dump_state()}
  end

  defp maybe_put_csrf(session, nil), do: session
  defp maybe_put_csrf(session, state), do: Map.put(session, "_csrf_token", state)

  defp hostname(value) do
    {:ok, hostname} = Hostname.parse(value)
    hostname
  end
end
