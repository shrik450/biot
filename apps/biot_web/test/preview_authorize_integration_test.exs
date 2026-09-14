defmodule BiotWeb.PreviewAuthorizeIntegrationTest do
  use BiotWeb.ConnCase, async: false

  alias Biot.Protocol.{Digest, Hostname, SameOriginPath}
  alias Biot.Server.PreviewHandoff
  alias Biot.Server.Repo
  alias Biot.Server.Schema.Publication
  alias Biot.Server.Sessions
  alias BiotWeb.Cookies
  alias BiotWeb.OidcPeer
  alias BiotWeb.TestFixtures

  setup do
    previous_oidc = Application.get_env(:biot_server, :oidc)
    peer = start_supervised!({OidcPeer, []})
    settings = OidcPeer.configuration(peer, "http://127.0.0.1:1/login/callback")
    Application.put_env(:biot_server, :oidc, settings)

    start_supervised!(
      {Oidcc.ProviderConfiguration.Worker,
       %{
         issuer: settings.issuer,
         name: Biot.Server.Login.Provider,
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

    stranger = TestFixtures.principal(2)
    node = TestFixtures.node(1)
    {biot, _environment} = TestFixtures.biot(owner, node, 1)
    {:ok, owner_token} = Sessions.start_control(owner.id)
    {:ok, stranger_token} = Sessions.start_control(stranger.id)
    hostname = hostname("preview-route")
    challenge = "preview-route-challenge"
    return_path = path("/app?tab=details")

    Repo.insert!(%Publication{
      biot_id: biot.id,
      port: TestFixtures.port(3_000),
      hostname: hostname,
      state: :active
    })

    on_exit(fn -> Application.put_env(:biot_server, :oidc, previous_oidc) end)

    %{
      peer: peer,
      owner: owner,
      owner_token: owner_token,
      stranger_token: stranger_token,
      hostname: hostname,
      challenge: challenge,
      return_path: return_path
    }
  end

  test "an authorized browser gets a callback code that is single use", context do
    response = get(browser_session(context.owner_token), authorize_path(context))
    assert response.status == 302

    location = hd(get_resp_header(response, "location"))
    uri = URI.parse(location)
    assert uri.path == "/__biot/callback"
    assert uri.host == Hostname.to_string(context.hostname) <> ".env.test"
    code = URI.decode_query(uri.query)["code"]
    assert is_binary(code)

    expected_return_path = context.return_path

    assert {:ok, %PreviewHandoff.Finished{return_path: ^expected_return_path}} =
             PreviewHandoff.finish(context.hostname, code, context.challenge)

    assert PreviewHandoff.finish(context.hostname, code, context.challenge) ==
             {:error, :unauthenticated}
  end

  test "an unauthenticated browser logs in and redeems a preview handoff", context do
    path = authorize_path(context)
    initial = get(build_conn(), path)
    assert initial.status == 302

    login_location = hd(get_resp_header(initial, "location"))
    login_uri = URI.parse(login_location)
    assert login_uri.path == "/login"
    assert URI.decode_query(login_uri.query)["return"] == path

    login_start = get(build_conn(), login_location)
    authorize_params = authorize(hd(get_resp_header(login_start, "location")))
    login_cookie = BiotWeb.ConnCase.cookie_value(login_start, Cookies.login_name())

    callback =
      build_conn()
      |> put_req_header("cookie", Cookies.login_name() <> "=" <> login_cookie)
      |> get("/login/callback?" <> URI.encode_query(authorize_params))

    assert callback.status == 302
    session_cookie = BiotWeb.ConnCase.cookie_value(callback, Cookies.session_name())
    assert is_binary(session_cookie)

    handoff =
      build_conn()
      |> put_req_header("cookie", Cookies.session_name() <> "=" <> session_cookie)
      |> get(path)

    assert handoff.status == 302

    callback_uri = URI.parse(hd(get_resp_header(handoff, "location")))
    assert callback_uri.host == Hostname.to_string(context.hostname) <> ".env.test"
    assert callback_uri.path == "/__biot/callback"
    code = URI.decode_query(callback_uri.query)["code"]
    assert is_binary(code)

    assert {:ok,
            %PreviewHandoff.Finished{
              token: preview_token,
              return_path: return_path
            }} =
             PreviewHandoff.finish(context.hostname, code, context.challenge)

    assert SameOriginPath.to_string(return_path) == "/app?tab=details"
    assert {:ok, preview_authentication} = Sessions.preview(context.hostname, preview_token)
    assert preview_authentication.actor.principal_id == context.owner.id

    assert PreviewHandoff.finish(context.hostname, code, context.challenge) ==
             {:error, :unauthenticated}
  end

  test "a session without view authority gets forbidden", context do
    response = get(browser_session(context.stranger_token), authorize_path(context))
    assert response.status == 403
  end

  test "invalid handoff parameters and inactive hosts return the route errors", context do
    assert get(
             browser_session(context.owner_token),
             "/preview/authorize?host=bad%20host&challenge=bad&return=%2F"
           ).status == 400

    missing_host = hostname("missing-preview")
    missing_path = authorize_path(%{context | hostname: missing_host})
    assert get(browser_session(context.owner_token), missing_path).status == 404

    external =
      "/preview/authorize?host=#{context.hostname}&challenge=#{Digest.to_string(Digest.sha256(context.challenge))}&return=https%3A%2F%2Fexample.com"

    assert get(browser_session(context.owner_token), external).status == 400
  end

  defp authorize_path(context) do
    query = %{
      "host" => Hostname.to_string(context.hostname),
      "challenge" => Digest.to_string(Digest.sha256(context.challenge)),
      "return" => SameOriginPath.to_string(context.return_path)
    }

    "/preview/authorize?" <> URI.encode_query(query)
  end

  defp browser_session(token) do
    Plug.Test.init_test_session(build_conn(), %{"token" => token})
  end

  defp path(value) do
    {:ok, path} = SameOriginPath.parse(value)
    path
  end

  defp hostname(value) do
    {:ok, hostname} = Hostname.parse(value)
    hostname
  end

  defp authorize(url) do
    {:ok, {{_version, 302, _reason}, headers, _body}} =
      :httpc.request(:get, {String.to_charlist(url), []}, [autoredirect: false],
        body_format: :binary
      )

    location =
      Enum.find_value(headers, fn {name, value} ->
        if String.downcase(to_string(name)) == "location", do: to_string(value)
      end)

    location
    |> URI.parse()
    |> Map.get(:query, "")
    |> URI.decode_query()
  end

  defp provider_ready?(attempts \\ 100)
  defp provider_ready?(0), do: false

  defp provider_ready?(attempts) do
    case {:ets.lookup(Biot.Server.Login.Provider, :provider_configuration),
          :ets.lookup(Biot.Server.Login.Provider, :jwks)} do
      {[{_, _configuration}], [{_, _jwks}]} ->
        true

      _values ->
        Process.sleep(20)
        provider_ready?(attempts - 1)
    end
  end
end
