defmodule BiotWeb.Api.Reply do
  @moduledoc "Sends a response that `BiotWeb.Api.Response` built."

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn

  alias BiotWeb.Api.Response

  @spec reply(Plug.Conn.t(), Response.t()) :: Plug.Conn.t()
  def reply(conn, {status, headers, nil}) do
    conn
    |> merge_resp_headers(headers)
    |> send_resp(status, "")
  end

  def reply(conn, {status, headers, body}) do
    conn
    |> merge_resp_headers(headers)
    |> put_status(status)
    |> json(body)
  end
end
