defmodule BiotWeb.LoginController do
  @moduledoc "Handles the browser side of the OIDC login flow."

  use BiotWeb, :controller

  alias Biot.Protocol.SameOriginPath
  alias Biot.Server.Login
  alias Biot.Server.Login.Pending
  alias BiotWeb.Cookies

  @login_salt "biot_login"

  @spec start(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def start(conn, params) do
    case return_path(params) do
      {:ok, return_path} -> start_login(conn, return_path)
      :error -> failure(conn, :bad_request, "Bad request")
    end
  end

  @spec callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def callback(conn, params) do
    conn
    |> fetch_cookies()
    |> login_pending()
    |> finish_login(conn, params)
  end

  defp return_path(%{"return" => value}), do: parse_return_path(value)
  defp return_path(_params), do: SameOriginPath.parse("/")

  defp parse_return_path(value) do
    case SameOriginPath.parse(value) do
      {:ok, return_path} -> {:ok, return_path}
      {:error, :invalid_format} -> :error
    end
  end

  defp start_login(%{assigns: %{authentication: authentication}} = conn, return_path)
       when not is_nil(authentication),
       do: redirect(conn, to: SameOriginPath.to_string(return_path))

  defp start_login(conn, return_path) do
    case Login.start(return_path) do
      {:ok, %{authorize_url: authorize_url, pending: pending}} ->
        conn
        |> put_resp_cookie(
          Cookies.login_name(),
          seal_pending(conn, pending),
          Cookies.login_options()
        )
        |> redirect(external: authorize_url)

      {:error, :temporarily_unavailable} ->
        failure(conn, :service_unavailable, "Login temporarily unavailable")
    end
  end

  defp login_pending(conn) do
    case get_cookies(conn)[Cookies.login_name()] do
      nil -> :missing
      value -> decrypt_pending(conn, value)
    end
  end

  defp decrypt_pending(conn, value) do
    case Plug.Crypto.decrypt(conn.secret_key_base, @login_salt, value,
           max_age: Cookies.login_max_age()
         ) do
      {:ok, %Pending{} = pending} -> {:ok, pending}
      _invalid_or_expired -> :invalid
    end
  end

  defp finish_login({:ok, %Pending{} = pending}, conn, params),
    do: finish_login(pending, conn, params)

  defp finish_login(%Pending{} = pending, conn, params) do
    case Login.finish(pending, params) do
      {:ok, %{token: token, return_path: return_path}} ->
        conn
        |> configure_session(renew: true)
        |> clear_session()
        |> put_session("token", token)
        |> delete_resp_cookie(Cookies.login_name(), Cookies.login_options())
        |> redirect(to: SameOriginPath.to_string(return_path))

      {:error, :unauthenticated} ->
        failure(conn, :unauthorized, "Login failed")

      {:error, :temporarily_unavailable} ->
        failure(conn, :service_unavailable, "Login temporarily unavailable")
    end
  end

  defp finish_login(_invalid_pending, conn, _params),
    do: failure(conn, :unauthorized, "Login failed")

  defp seal_pending(conn, %Pending{} = pending),
    do:
      Plug.Crypto.encrypt(conn.secret_key_base, @login_salt, pending,
        max_age: Cookies.login_max_age()
      )

  defp failure(conn, status, body), do: conn |> put_status(status) |> html(body)
end
