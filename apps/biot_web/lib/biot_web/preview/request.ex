defmodule BiotWeb.Preview.Request do
  @moduledoc """
  Builds the upstream HTTP/1.1 request for one preview request.

  It is pure: it reads the inbound `Plug.Conn` headers and identity and returns bytes. Biot-owned
  headers are removed and replaced, so the application can never see or forge a Biot cookie,
  credential header, or forwarding header. Application `Authorization` and application cookies
  pass through unchanged.
  """

  alias Biot.Protocol.PrincipalId
  alias Plug.Conn

  @hop_by_hop ~w(connection keep-alive proxy-authenticate proxy-authorization te trailer transfer-encoding upgrade)
  @biot_cookie_prefix "__Host-biot_"

  @type identity :: %{
          principal_id: PrincipalId.t(),
          email: String.t() | nil,
          name: String.t() | nil
        }

  @spec head(Conn.t(), identity()) :: iodata()
  def head(%Conn{} = conn, identity) do
    connection_tokens = connection_tokens(conn.req_headers)

    headers =
      conn.req_headers
      |> Enum.reject(&drop?(&1, connection_tokens))
      |> rewrite_cookie()
      |> forwarding(conn, identity, "close")

    [
      conn.method,
      " ",
      request_target(conn),
      " HTTP/1.1\r\n",
      Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "\r\n"
    ]
  end

  @doc """
  Builds the upstream WebSocket handshake request.

  The client's `Upgrade` and `Sec-WebSocket-*` headers are kept, `permessage-deflate` is dropped
  so the application never negotiates a compression the relay cannot see through, and the same
  Biot-owned headers are rewritten as for a plain request.
  """
  @spec upgrade_head(Conn.t(), identity()) :: iodata()
  def upgrade_head(%Conn{} = conn, identity) do
    headers =
      conn.req_headers
      |> Enum.reject(&upgrade_drop?/1)
      |> rewrite_cookie()
      |> forwarding(conn, identity, "Upgrade")

    [
      conn.method,
      " ",
      request_target(conn),
      " HTTP/1.1\r\n",
      Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "\r\n"
    ]
  end

  defp forwarding(headers, conn, identity, connection_value) do
    headers
    |> Kernel.++([
      {"x-biot-principal-id", PrincipalId.to_string(identity.principal_id)},
      {"x-forwarded-proto", "https"},
      {"x-forwarded-host", conn.host},
      {"x-forwarded-for", client_address(conn)},
      {"connection", connection_value}
    ])
    |> maybe_claim("x-biot-email", identity.email)
    |> maybe_claim("x-biot-name", identity.name)
  end

  # The upgrade keeps the client's Upgrade header; the proxy supplies its own Connection header.
  defp upgrade_drop?({name, _value}) do
    (name in @hop_by_hop and name != "upgrade") or name == "sec-websocket-extensions" or
      name == "forwarded" or String.starts_with?(name, "x-biot-") or
      String.starts_with?(name, "x-forwarded-")
  end

  # A proxy sets its own connection header, so the client's is never forwarded.
  defp drop?({name, _value}, connection_tokens) do
    name in @hop_by_hop or name in connection_tokens or name == "forwarded" or
      String.starts_with?(name, "x-biot-") or String.starts_with?(name, "x-forwarded-")
  end

  # Every Biot cookie is dropped; the application's own cookies are kept exactly as sent.
  defp rewrite_cookie(headers) do
    Enum.flat_map(headers, fn
      {"cookie", value} ->
        case kept_cookies(value) do
          [] -> []
          cookies -> [{"cookie", Enum.join(cookies, "; ")}]
        end

      header ->
        [header]
    end)
  end

  defp kept_cookies(value) do
    value
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, @biot_cookie_prefix)))
  end

  # The client's Connection header names other hop-by-hop headers to remove.
  defp connection_tokens(headers) do
    headers
    |> Enum.filter(fn {name, _value} -> name == "connection" end)
    |> Enum.flat_map(fn {_name, value} -> String.split(value, ",") end)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
  end

  defp maybe_claim(headers, _name, nil), do: headers

  defp maybe_claim(headers, name, value) do
    if valid_field_value?(value), do: headers ++ [{name, value}], else: headers
  end

  # The authoritative principal id is a canonical UUID. Optional claims are dropped when they
  # cannot be a valid HTTP field value, so a claim can never inject a header or split a message.
  defp valid_field_value?(value) do
    value != "" and not String.match?(value, ~r/[\x00-\x1f\x7f]/)
  end

  defp client_address(conn) do
    conn.remote_ip
    |> :inet.ntoa()
    |> to_string()
  end

  defp request_target(conn) do
    case conn.query_string do
      "" -> conn.request_path
      query -> conn.request_path <> "?" <> query
    end
  end
end
