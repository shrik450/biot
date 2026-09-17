defmodule BiotWeb.Preview.Upgrade do
  @moduledoc """
  The controller side of a preview WebSocket upgrade.

  It authenticates the caller, applies the Origin rule for the authentication surface, and only
  then hands the request to `BiotWeb.Preview.Socket`. The stream itself is opened by the socket
  process, which is the owner that must close it.
  """

  import Plug.Conn

  alias Biot.Protocol.Hostname
  alias Biot.Server.Publications
  alias BiotWeb.Preview.{Identity, Origin, Page, Request, Socket, WebSocket}

  @doc "Whether this request asks to upgrade the connection to a WebSocket."
  @spec upgrade?(Plug.Conn.t()) :: boolean()
  def upgrade?(conn) do
    conn.method == "GET" and
      any_header?(get_req_header(conn, "upgrade"), "websocket") and
      any_header?(get_req_header(conn, "connection"), "upgrade")
  end

  @spec call(Plug.Conn.t(), Hostname.t()) :: Plug.Conn.t()
  def call(conn, hostname) do
    case Identity.resolve(conn, hostname) do
      {:ok, authentication, source} ->
        case Origin.allowed?(source, get_req_header(conn, "origin"), Publications.url(hostname)) do
          :ok -> upgrade(conn, hostname, authentication)
          {:error, :foreign_origin} -> refuse(conn, :forbidden)
        end

      # A WebSocket cannot complete a redirect, so a caller with no session is simply refused.
      :handoff ->
        refuse(conn, :unauthenticated)

      {:error, reason} ->
        refuse(conn, reason)
    end
  end

  defp upgrade(conn, hostname, authentication) do
    handshake = Request.upgrade_head(conn, Identity.headers(authentication))
    key = conn |> get_req_header("sec-websocket-key") |> List.first()
    max = WebSocket.max_bytes()

    conn
    |> WebSockAdapter.upgrade(
      Socket,
      %{authentication: authentication, hostname: hostname, handshake: handshake, key: key},
      timeout: :infinity,
      max_frame_size: max,
      compress: false
    )
    |> halt()
  end

  defp refuse(conn, result), do: conn |> Page.render(result) |> halt()

  defp any_header?(values, needle) do
    Enum.any?(values, &String.contains?(String.downcase(&1), needle))
  end
end
