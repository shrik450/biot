defmodule BiotWeb.OidcPeer do
  @moduledoc """
  A small OIDC provider used by the web integration checks.

  The provider uses a real Bandit listener and an RSA signing key. It keeps authorization codes
  in the peer process so every code exchange checks the same state that the authorization request
  recorded.
  """

  use GenServer

  @default_client_id "biot-test-client"
  @default_client_secret "biot-test-secret"
  @default_user %{subject: "biot-test-subject", email: "user@example.test", name: "Test User"}
  @default_key_id "biot-test-key"

  defstruct [
    :listener,
    :issuer,
    :client_id,
    :client_secret,
    :user,
    :signing_key,
    :key_id,
    codes: %{},
    last_authorization: nil
  ]

  @type t :: pid()

  @type user :: %{
          optional(:subject) => String.t(),
          optional(:email) => String.t(),
          optional(:name) => String.t()
        }

  @type options :: [
          {:client_id, String.t()},
          {:client_secret, String.t()},
          {:user, user()},
          {:port, :inet.port_number()},
          {:name, GenServer.name()}
        ]

  @spec start_link(options()) :: GenServer.on_start()
  def start_link(options \\ []) do
    {name, peer_options} = Keyword.pop(options, :name)
    gen_server_options = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, peer_options, gen_server_options)
  end

  @spec stop(t()) :: :ok
  def stop(peer), do: GenServer.stop(peer)

  @spec issuer(t()) :: String.t()
  def issuer(peer), do: GenServer.call(peer, :issuer)

  @spec url(t()) :: String.t()
  def url(peer), do: issuer(peer)

  @spec client_id(t()) :: String.t()
  def client_id(peer), do: GenServer.call(peer, :client_id)

  @spec client_secret(t()) :: String.t()
  def client_secret(peer), do: GenServer.call(peer, :client_secret)

  @spec configuration(t(), String.t()) :: map()
  def configuration(peer, redirect_uri),
    do: %{
      issuer: issuer(peer),
      client_id: client_id(peer),
      client_secret: client_secret(peer),
      redirect_uri: redirect_uri
    }

  @spec last_authorization(t()) :: map() | nil
  def last_authorization(peer), do: GenServer.call(peer, :last_authorization)

  @impl true
  def init(options) do
    {:ok, signing_key} = generate_signing_key()

    {:ok, listener} =
      Bandit.start_link(
        plug: {BiotWeb.OidcPeer.Router, [peer: self()]},
        port: Keyword.get(options, :port, 0),
        ip: :loopback,
        startup_log: false
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(listener)

    state = %__MODULE__{
      listener: listener,
      issuer: "http://127.0.0.1:#{port}",
      client_id: Keyword.get(options, :client_id, @default_client_id),
      client_secret: Keyword.get(options, :client_secret, @default_client_secret),
      user: normalize_user(Keyword.get(options, :user, @default_user)),
      signing_key: signing_key,
      key_id: @default_key_id
    }

    {:ok, state}
  end

  @impl true
  def terminate(_reason, %{listener: listener}) do
    _ = ThousandIsland.stop(listener)
    :ok
  end

  @impl true
  def handle_call(:issuer, _from, %{issuer: issuer} = state), do: {:reply, issuer, state}

  def handle_call(:client_id, _from, %{client_id: client_id} = state),
    do: {:reply, client_id, state}

  def handle_call(:client_secret, _from, %{client_secret: client_secret} = state),
    do: {:reply, client_secret, state}

  def handle_call(:last_authorization, _from, %{last_authorization: request} = state),
    do: {:reply, request, state}

  def handle_call(:discovery, _from, state),
    do: {:reply, discovery(state), state}

  def handle_call(:jwks, _from, state), do: {:reply, jwks(state), state}

  def handle_call({:authorize, params}, _from, state) do
    case authorize(params, state) do
      {:ok, redirect_uri, code, request} ->
        {:reply, {:redirect, redirect_uri, code, request},
         %{state | codes: Map.put(state.codes, code, request), last_authorization: request}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:token, params, headers}, _from, state) do
    case token(params, headers, state) do
      {:ok, response, code} ->
        {:reply, {:token, response}, %{state | codes: Map.delete(state.codes, code)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp generate_signing_key do
    {:ok, JOSE.JWK.generate_key({:rsa, 2048})}
  rescue
    error -> {:error, error}
  end

  defp normalize_user(user) do
    %{
      subject: Map.get(user, :subject, Map.get(user, "subject", "biot-test-subject")),
      email: Map.get(user, :email, Map.get(user, "email", "user@example.test")),
      name: Map.get(user, :name, Map.get(user, "name", "Test User"))
    }
  end

  defp discovery(%{issuer: issuer}) do
    %{
      "issuer" => issuer,
      "authorization_endpoint" => "#{issuer}/authorize",
      "token_endpoint" => "#{issuer}/token",
      "jwks_uri" => "#{issuer}/jwks",
      "scopes_supported" => ["openid", "email", "profile"],
      "response_types_supported" => ["code"],
      "subject_types_supported" => ["public"],
      "id_token_signing_alg_values_supported" => ["RS256"],
      "grant_types_supported" => ["authorization_code"],
      "token_endpoint_auth_methods_supported" => ["client_secret_post", "client_secret_basic"],
      "code_challenge_methods_supported" => ["S256"],
      "claims_supported" => ["iss", "sub", "aud", "azp", "exp", "iat", "nonce", "email", "name"]
    }
  end

  defp jwks(%{signing_key: signing_key, key_id: key_id}) do
    public_key = JOSE.JWK.to_public(signing_key)

    %{
      "keys" => [
        public_key
        |> JOSE.JWK.merge(%{"kid" => key_id, "alg" => "RS256", "use" => "sig"})
        |> JOSE.JWK.to_public_map()
        |> elem(1)
      ]
    }
  end

  defp authorize(params, %{client_id: client_id}) do
    with "code" <- params["response_type"],
         ^client_id <- params["client_id"],
         redirect_uri when is_binary(redirect_uri) <- params["redirect_uri"],
         state when is_binary(state) <- params["state"],
         nonce when is_binary(nonce) <- params["nonce"],
         "S256" <- params["code_challenge_method"],
         challenge when is_binary(challenge) <- params["code_challenge"] do
      code = random_value()

      request = %{
        redirect_uri: redirect_uri,
        state: state,
        nonce: nonce,
        code_challenge: challenge,
        code_challenge_method: "S256"
      }

      {:ok, append_query(redirect_uri, %{"code" => code, "state" => state}), code, request}
    else
      _value -> {:error, :invalid_authorization_request}
    end
  end

  defp token(params, headers, %{client_id: client_id, client_secret: client_secret} = state) do
    with :ok <- authenticate_client(params, headers, client_id, client_secret),
         code when is_binary(code) <- params["code"],
         %{redirect_uri: redirect_uri, code_challenge: challenge} = request <- state.codes[code],
         ^redirect_uri <- params["redirect_uri"],
         verifier when is_binary(verifier) <- params["code_verifier"],
         ^challenge <- code_challenge(verifier) do
      {:ok, token_response(state, request, client_id), code}
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :invalid_grant}
      _value -> {:error, :invalid_grant}
    end
  end

  defp authenticate_client(params, headers, client_id, client_secret) do
    case basic_credentials(headers) do
      {^client_id, ^client_secret} ->
        :ok

      nil ->
        if params["client_id"] == client_id and params["client_secret"] == client_secret,
          do: :ok,
          else: {:error, :invalid_client}

      _credentials ->
        {:error, :invalid_client}
    end
  end

  defp basic_credentials(headers) do
    headers
    |> authorization_header()
    |> decode_basic_credentials()
  end

  defp authorization_header(headers) do
    Enum.find_value(headers, fn {name, value} ->
      if String.downcase(name) == "authorization", do: value
    end)
  end

  defp decode_basic_credentials("Basic " <> encoded) do
    with {:ok, decoded} <- Base.decode64(encoded),
         [client_id, client_secret] <- String.split(decoded, ":", parts: 2) do
      {client_id, client_secret}
    else
      _value -> :invalid
    end
  end

  defp decode_basic_credentials(_value), do: nil

  defp code_challenge(verifier),
    do: Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

  defp token_response(
         %{issuer: issuer, signing_key: signing_key, key_id: key_id, user: user},
         request,
         client_id
       ) do
    now = System.system_time(:second)

    claims = %{
      "iss" => issuer,
      "sub" => user.subject,
      "aud" => client_id,
      "azp" => client_id,
      "exp" => now + 300,
      "iat" => now,
      "nonce" => request.nonce,
      "email" => user.email,
      "name" => user.name
    }

    jwt =
      signing_key
      |> JOSE.JWT.sign(
        %{"alg" => "RS256", "typ" => "JWT", "kid" => key_id},
        JOSE.JWT.from(claims)
      )
      |> JOSE.JWS.compact()
      |> elem(1)

    %{
      "access_token" => random_value(),
      "token_type" => "Bearer",
      "expires_in" => 300,
      "id_token" => jwt,
      "scope" => "openid email profile"
    }
  end

  defp random_value, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp append_query(uri, params) do
    parsed = URI.parse(uri)
    query = URI.encode_query(params)
    %{parsed | query: join_query(parsed.query, query)} |> URI.to_string()
  end

  defp join_query(nil, query), do: query
  defp join_query(existing, query), do: existing <> "&" <> query

  defmodule Router do
    @moduledoc false

    use Plug.Router, copy_opts_to_assign: :router_options

    plug Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"]
    plug :match
    plug :dispatch

    get "/.well-known/openid-configuration" do
      peer = conn.assigns.router_options[:peer]
      json(conn, GenServer.call(peer, :discovery))
    end

    get "/jwks" do
      peer = conn.assigns.router_options[:peer]
      json(conn, GenServer.call(peer, :jwks))
    end

    get "/authorize" do
      peer = conn.assigns.router_options[:peer]

      case GenServer.call(peer, {:authorize, conn.params}) do
        {:redirect, location, _code, _request} ->
          conn |> put_resp_header("location", location) |> send_resp(302, "")

        {:error, reason} ->
          json(conn, %{"error" => Atom.to_string(reason)}, 400)
      end
    end

    post "/token" do
      peer = conn.assigns.router_options[:peer]

      case GenServer.call(peer, {:token, conn.body_params, conn.req_headers}) do
        {:token, response} -> json(conn, response)
        {:error, reason} -> json(conn, %{"error" => Atom.to_string(reason)}, 400)
      end
    end

    match _ do
      send_resp(conn, 404, "not found")
    end

    defp json(conn, body, status \\ 200) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end
  end
end
