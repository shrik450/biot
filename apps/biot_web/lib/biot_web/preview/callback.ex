defmodule BiotWeb.Preview.Callback do
  @moduledoc """
  Consumes the single-use preview handoff code on the preview host.

  It reads the challenge cookie the proxy set before the redirect, exchanges the code through
  `PreviewHandoff.finish/3`, then sets the preview session cookie, clears the handoff, and
  returns the browser to the path it first asked for.
  """

  import Plug.Conn

  alias Biot.Protocol.SameOriginPath
  alias Biot.Server.PreviewHandoff
  alias BiotWeb.Cookies
  alias BiotWeb.Preview.Failure

  @spec call(Plug.Conn.t(), Biot.Protocol.Hostname.t()) :: Plug.Conn.t()
  def call(conn, hostname) do
    conn = conn |> fetch_query_params() |> fetch_cookies()

    with {:ok, code} <- code(conn),
         challenge when is_binary(challenge) <- conn.req_cookies[Cookies.handoff_name()],
         {:ok, finished} <- PreviewHandoff.finish(hostname, code, challenge) do
      conn
      |> put_resp_cookie(Cookies.preview_name(), finished.token, Cookies.preview_options())
      |> delete_resp_cookie(Cookies.handoff_name(), Cookies.handoff_options())
      |> put_resp_header("location", SameOriginPath.to_string(finished.return_path))
      |> send_resp(302, "")
    else
      _missing_or_rejected -> failure(conn)
    end
  end

  defp code(conn) do
    case conn.query_params["code"] do
      code when is_binary(code) and code != "" -> {:ok, code}
      _missing -> :error
    end
  end

  defp failure(conn) do
    {status, body} = Failure.response(:unauthenticated, BiotWeb.Endpoint.url())

    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, body)
  end
end
