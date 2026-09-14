defmodule BiotWeb.Api.FallbackController do
  @moduledoc "Sends the error an API action returns as its status and JSON body."

  use Phoenix.Controller, formats: [:json]

  import Plug.Conn

  alias Biot.Server.CommandError
  alias BiotWeb.Api.ErrorResponse

  @spec call(Plug.Conn.t(), :not_found) :: Plug.Conn.t()
  def call(conn, :not_found), do: not_found(conn, %{})

  @spec call(Plug.Conn.t(), {:error, CommandError.t()}) :: Plug.Conn.t()
  def call(conn, {:error, error}) do
    {status, body} = ErrorResponse.build(error)

    conn
    |> put_status(status)
    |> json(body)
  end

  @spec not_found(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def not_found(conn, _params), do: call(conn, {:error, :not_found})
end
