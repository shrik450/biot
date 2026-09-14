defmodule BiotWeb.OidcLoginIntegrationTest do
  use BiotWeb.ConnCase, async: false

  alias Biot.Protocol.SameOriginPath
  alias Biot.Server.Login
  alias Biot.Server.Login.Callback
  alias Biot.Server.Login.Pending
  alias Biot.Server.Repo
  alias Biot.Server.Schema.Principal
  alias Biot.Server.Sessions
  alias BiotWeb.Cookies
  alias BiotWeb.OidcPeer

  setup do
    previous_oidc = Application.get_env(:biot_server, :oidc)
    peer = start_supervised!({OidcPeer, []})
    redirect_uri = "http://127.0.0.1:1/login/callback"
    settings = OidcPeer.configuration(peer, redirect_uri)
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

    on_exit(fn -> Application.put_env(:biot_server, :oidc, previous_oidc) end)

    %{peer: peer, settings: settings}
  end

  test "callback parsing requires a matching state and code" do
    assert Callback.parse(%{"state" => "expected", "code" => "code"}, "expected") ==
             {:ok, "code"}

    assert Callback.parse(%{"state" => "wrong", "code" => "code"}, "expected") == :error
    assert Callback.parse(%{"state" => "expected"}, "expected") == :error

    assert Callback.parse(
             %{"state" => "expected", "code" => "code", "error" => "denied"},
             "expected"
           ) ==
             :error
  end

  test "a real provider flow creates and then reuses the principal", context do
    path = path("/dashboard?from=login")

    {first_pending, first_callback} = pending_callback(path)

    assert {:ok, %{token: first_token, return_path: ^path}} =
             Login.finish(first_pending, first_callback)

    assert {:ok, _authentication} = Sessions.control(first_token)

    principal =
      Repo.get_by!(Principal, issuer: context.settings.issuer, subject: "biot-test-subject")

    assert principal.status == :enabled
    assert principal.last_seen_email == "user@example.test"
    assert principal.last_seen_name == "Test User"

    {second_pending, second_callback} = pending_callback(path)

    assert {:ok, %{token: second_token, return_path: ^path}} =
             Login.finish(second_pending, second_callback)

    assert {:ok, _authentication} = Sessions.control(second_token)
    assert Repo.aggregate(Principal, :count) == 1
    assert Repo.get!(Principal, principal.id).id == principal.id
  end

  test "state, PKCE, nonce, and disabled principal failures stay unauthenticated", _context do
    path = path("/dashboard")
    {pending, callback} = pending_callback(path)

    assert Login.finish(pending, Map.put(callback, "state", "wrong")) ==
             {:error, :unauthenticated}

    assert Login.finish(pending, %{"state" => pending.state, "error" => "access_denied"}) ==
             {:error, :unauthenticated}

    assert Login.finish(%{pending | pkce_verifier: "wrong-verifier"}, callback) ==
             {:error, :unauthenticated}

    assert Login.finish(%{pending | nonce: "wrong-nonce"}, callback) ==
             {:error, :unauthenticated}

    {valid_pending, valid_callback} = pending_callback(path)
    assert {:ok, %{token: token}} = Login.finish(valid_pending, valid_callback)
    assert {:ok, authentication} = Sessions.control(token)
    principal = Repo.get!(Principal, authentication.actor.principal_id)
    Repo.update!(Ecto.Changeset.change(principal, status: :disabled))

    {disabled_pending, disabled_callback} = pending_callback(path)
    assert Login.finish(disabled_pending, disabled_callback) == {:error, :unauthenticated}
    assert Repo.aggregate(Principal, :count) == 1
  end

  test "missing provider configuration and a down provider are temporary failures", context do
    path = path("/")
    Application.put_env(:biot_server, :oidc, nil)
    assert Login.start(path) == {:error, :temporarily_unavailable}

    Application.put_env(:biot_server, :oidc, context.settings)
    {pending, callback} = pending_callback(path)
    OidcPeer.stop(context.peer)
    assert Login.finish(pending, callback) == {:error, :temporarily_unavailable}
  end

  test "browser login seals state and accepts only a valid callback", context do
    start = get(build_conn(), "/login?return=/biots")
    assert start.status == 302

    assert get_resp_header(start, "location")
           |> hd()
           |> String.starts_with?(context.settings.issuer)

    authorize_params = authorize(hd(get_resp_header(start, "location")))
    login_cookie = BiotWeb.ConnCase.cookie_value(start, Cookies.login_name())
    callback_path = "/login/callback?" <> URI.encode_query(authorize_params)

    callback =
      build_conn()
      |> put_req_header("cookie", Cookies.login_name() <> "=" <> login_cookie)
      |> get(callback_path)

    assert callback.status == 302
    assert get_resp_header(callback, "location") == ["/biots"]
    assert BiotWeb.ConnCase.cookie_value(callback, Cookies.session_name())
    assert Enum.any?(get_resp_header(callback, "set-cookie"), &String.contains?(&1, "max-age=0"))

    session_cookie = BiotWeb.ConnCase.cookie_value(callback, Cookies.session_name())

    live =
      build_conn()
      |> put_req_header("cookie", Cookies.session_name() <> "=" <> session_cookie)
      |> get("/login?return=/renewed")

    assert live.status == 302
    assert get_resp_header(live, "location") == ["/renewed"]
  end

  test "browser rejects malformed returns and missing, forged, or expired login state" do
    assert get(build_conn(), "/login?return=https%3A%2F%2Fexample.com").status == 400
    assert get(build_conn(), "/login?return=%2F%2Fexample.com").status == 400

    missing_cookie = get(build_conn(), "/login/callback?code=ignored&state=ignored")
    assert missing_cookie.status == 401
    assert missing_cookie.resp_body == "Login failed"

    forged_cookie =
      build_conn()
      |> put_req_header("cookie", Cookies.login_name() <> "=forged")
      |> get("/login/callback?code=ignored&state=ignored")

    assert forged_cookie.status == 401
    assert forged_cookie.resp_body == "Login failed"

    path = path("/expired")

    pending = %Pending{
      state: "expired-state",
      nonce: "expired-nonce",
      pkce_verifier: "expired-verifier",
      return_path: path
    }

    expired =
      Plug.Crypto.encrypt(
        BiotWeb.Endpoint.config(:secret_key_base),
        "biot_login",
        pending,
        signed_at: System.system_time(:second) - 601,
        max_age: Cookies.login_max_age()
      )

    conn =
      build_conn()
      |> put_req_header("cookie", Cookies.login_name() <> "=" <> expired)
      |> get("/login/callback?code=ignored&state=ignored")

    assert conn.status == 401
    assert conn.resp_body == "Login failed"
  end

  test "the callback renews and rotates an existing browser session cookie", _context do
    first_start = get(build_conn(), "/login?return=/first")
    first_authorize_params = authorize(hd(get_resp_header(first_start, "location")))
    first_login_cookie = BiotWeb.ConnCase.cookie_value(first_start, Cookies.login_name())

    first_callback =
      build_conn()
      |> put_req_header("cookie", Cookies.login_name() <> "=" <> first_login_cookie)
      |> get("/login/callback?" <> URI.encode_query(first_authorize_params))

    assert first_callback.status == 302

    existing_session_cookie =
      BiotWeb.ConnCase.cookie_value(first_callback, Cookies.session_name())

    assert is_binary(existing_session_cookie)
    first_token = Plug.Conn.get_session(first_callback, "token")
    assert is_binary(first_token)
    assert {:ok, _} = Sessions.control(first_token)
    assert Sessions.logout(first_token) == :ok

    second_start = get(build_conn(), "/login?return=/second")
    second_authorize_params = authorize(hd(get_resp_header(second_start, "location")))
    second_login_cookie = BiotWeb.ConnCase.cookie_value(second_start, Cookies.login_name())

    second_callback =
      build_conn()
      |> put_req_header(
        "cookie",
        Cookies.session_name() <>
          "=" <>
          existing_session_cookie <>
          "; " <>
          Cookies.login_name() <>
          "=" <>
          second_login_cookie
      )
      |> get("/login/callback?" <> URI.encode_query(second_authorize_params))

    assert second_callback.status == 302
    assert get_resp_header(second_callback, "location") == ["/second"]

    renewed_session_cookie =
      BiotWeb.ConnCase.cookie_value(second_callback, Cookies.session_name())

    assert is_binary(renewed_session_cookie)
    refute renewed_session_cookie == existing_session_cookie

    renewed_token = Plug.Conn.get_session(second_callback, "token")
    assert is_binary(renewed_token)
    assert renewed_token != first_token
    assert {:ok, _} = Sessions.control(renewed_token)
    assert Sessions.control(first_token) == :error
  end

  defp path(value) do
    {:ok, path} = SameOriginPath.parse(value)
    path
  end

  defp pending_callback(return_path) do
    {:ok, %{authorize_url: authorize_url, pending: pending}} = Login.start(return_path)
    {pending, authorize(authorize_url)}
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
