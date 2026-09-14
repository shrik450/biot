defmodule Biot.Server.Login do
  @moduledoc "Runs the OIDC authorization-code flow and starts control sessions."

  alias Biot.Protocol.SameOriginPath
  alias Biot.Server.Login.Callback
  alias Biot.Server.Login.Pending
  alias Biot.Server.Principals
  alias Biot.Server.Schema.Principal
  alias Biot.Server.Sessions

  @type result ::
          {:ok, %{authorize_url: String.t(), pending: Pending.t()}}
          | {:error, :temporarily_unavailable}

  @type finish_result ::
          {:ok, %{token: String.t(), return_path: SameOriginPath.t()}}
          | {:error, :unauthenticated | :temporarily_unavailable}

  @spec start(SameOriginPath.t()) :: result()
  def start(%SameOriginPath{} = return_path) do
    pending = %Pending{
      state: random_value(),
      nonce: random_value(),
      pkce_verifier: random_value(),
      return_path: return_path
    }

    with {:ok, settings} <- oidc_settings(),
         {:ok, authorize_url} <- create_redirect_url(settings, pending) do
      {:ok, %{authorize_url: IO.iodata_to_binary(authorize_url), pending: pending}}
    else
      _reason -> {:error, :temporarily_unavailable}
    end
  end

  @spec finish(Pending.t(), map()) :: finish_result()
  def finish(%Pending{} = pending, callback_params) when is_map(callback_params) do
    with {:ok, code} <- Callback.parse(callback_params, pending.state),
         {:ok, settings} <- oidc_settings(),
         {:ok, token} <- retrieve_token(settings, pending, code),
         {:ok, claims} <- identity_claims(token),
         {:ok, %Principal{id: principal_id}} <- identify(claims),
         {:ok, session_token} <- Sessions.start_control(principal_id) do
      {:ok, %{token: session_token, return_path: pending.return_path}}
    else
      {:error, reason} -> {:error, finish_error(reason)}
      :error -> {:error, :unauthenticated}
    end
  end

  def finish(_pending, _callback_params), do: {:error, :unauthenticated}

  defp oidc_settings do
    case Application.get_env(:biot_server, :oidc) do
      %{
        issuer: issuer,
        client_id: client_id,
        client_secret: client_secret,
        redirect_uri: redirect_uri
      }
      when is_binary(issuer) and is_binary(client_id) and is_binary(client_secret) and
             is_binary(redirect_uri) ->
        {:ok,
         %{
           issuer: issuer,
           client_id: client_id,
           client_secret: client_secret,
           redirect_uri: redirect_uri
         }}

      _missing_or_invalid ->
        :error
    end
  end

  defp create_redirect_url(settings, %Pending{} = pending) do
    Oidcc.create_redirect_url(
      Biot.Server.Login.Provider,
      settings.client_id,
      settings.client_secret,
      %{
        redirect_uri: settings.redirect_uri,
        state: pending.state,
        nonce: pending.nonce,
        pkce_verifier: pending.pkce_verifier,
        require_pkce: true,
        scopes: ["openid", "email", "profile"]
      }
    )
  end

  defp retrieve_token(settings, %Pending{} = pending, code) do
    case Oidcc.retrieve_token(
           code,
           Biot.Server.Login.Provider,
           settings.client_id,
           settings.client_secret,
           %{
             redirect_uri: settings.redirect_uri,
             pkce_verifier: pending.pkce_verifier,
             require_pkce: true,
             nonce: pending.nonce
           }
         ) do
      {:ok, token} -> {:ok, token}
      {:error, reason} -> {:error, reason}
    end
  end

  defp identity_claims(%Oidcc.Token{id: %Oidcc.Token.Id{claims: claims}}) when is_map(claims) do
    with issuer when is_binary(issuer) <- claims["iss"],
         subject when is_binary(subject) <- claims["sub"],
         {:ok, email} <- optional_claim(claims["email"]),
         {:ok, name} <- optional_claim(claims["name"]) do
      {:ok, %{issuer: issuer, subject: subject, email: email, name: name}}
    else
      _invalid_claims -> {:error, :invalid_claims}
    end
  end

  defp identity_claims(_token), do: {:error, :invalid_claims}

  defp optional_claim(nil), do: {:ok, nil}
  defp optional_claim(value) when is_binary(value), do: {:ok, value}
  defp optional_claim(_value), do: {:error, :invalid_claim}

  defp identify(%{issuer: issuer, subject: subject, email: email, name: name}) do
    Principals.identify(issuer, subject, %{email: email, name: name})
  end

  defp finish_error(reason) do
    if provider_unavailable?(reason), do: :temporarily_unavailable, else: :unauthenticated
  end

  defp provider_unavailable?(:provider_not_ready), do: true
  defp provider_unavailable?(:timeout), do: true
  defp provider_unavailable?(:nxdomain), do: true
  defp provider_unavailable?(:econnrefused), do: true
  defp provider_unavailable?(:econnreset), do: true
  defp provider_unavailable?(:closed), do: true

  defp provider_unavailable?({:http_error, status, _body}) when status >= 500, do: true
  defp provider_unavailable?({:failed_connect, _details}), do: true
  defp provider_unavailable?({:tls_alert, _details}), do: true

  defp provider_unavailable?(reason) when is_tuple(reason) do
    reason |> Tuple.to_list() |> Enum.any?(&provider_unavailable?/1)
  end

  defp provider_unavailable?(reason) when is_list(reason),
    do: Enum.any?(reason, &provider_unavailable?/1)

  defp provider_unavailable?(_reason), do: false

  defp random_value, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
end
