defmodule BiotWeb.Preview.Identity do
  @moduledoc """
  Resolves the caller of one preview request to an authentication proof and its source.

  The surface is chosen by which proof is presented, and only which: a request with an
  `X-Biot-Authorization` header is authenticated by credential even if the credential is bad, so a
  bad credential never falls back to a cookie. A request without that header uses the preview
  session cookie, or begins the handoff when there is none.
  """

  import Plug.Conn

  alias Biot.Protocol.Hostname
  alias Biot.Server.Authentication
  alias Biot.Server.Credentials
  alias Biot.Server.Principals
  alias Biot.Server.Queries.PrincipalView
  alias Biot.Server.Sessions
  alias BiotWeb.Api.BearerHeader
  alias BiotWeb.Cookies

  @type source :: :cookie | :credential

  @spec resolve(Plug.Conn.t(), Hostname.t()) ::
          {:ok, Authentication.t(), source()} | :handoff | {:error, :unauthenticated}
  def resolve(conn, hostname) do
    conn = fetch_cookies(conn)

    case get_req_header(conn, "x-biot-authorization") do
      [] -> cookie(conn, hostname)
      values -> credential(values)
    end
  end

  defp credential(values) do
    with {:ok, token} <- BearerHeader.token(values),
         {:ok, authentication} <- Credentials.authenticate(token) do
      {:ok, authentication, :credential}
    else
      _invalid -> {:error, :unauthenticated}
    end
  end

  defp cookie(conn, hostname) do
    case conn.req_cookies[Cookies.preview_name()] do
      nil ->
        :handoff

      token ->
        case Sessions.preview(hostname, token) do
          {:ok, authentication} -> {:ok, authentication, :cookie}
          :error -> :handoff
        end
    end
  end

  @doc "The identity headers the proxy writes for one authentication."
  @spec headers(Authentication.t()) :: BiotWeb.Preview.Request.identity()
  def headers(%Authentication{actor: actor}) do
    view =
      case Principals.get(actor) do
        {:ok, view} -> view
        {:error, _reason} -> %PrincipalView{id: actor.principal_id, email: nil, name: nil}
      end

    %{principal_id: actor.principal_id, email: view.email, name: view.name}
  end
end
