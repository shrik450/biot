defmodule BiotWeb.Preview.Page do
  @moduledoc "Renders one Biot preview failure page on a connection."

  alias BiotWeb.Preview.Failure

  @doc "Sends the page for `result` and halts nothing; the caller owns the connection."
  @spec render(Plug.Conn.t(), atom()) :: Plug.Conn.t()
  def render(conn, result) do
    {status, body} = Failure.response(result, BiotWeb.Endpoint.url())

    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> Plug.Conn.send_resp(status, body)
  end
end
