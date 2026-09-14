defmodule BiotWeb.Api.Bearer do
  @moduledoc """
  Authenticates an API request by its bearer credential and assigns `:authentication`.

  The API reads no cookies, so a browser session never authenticates an API request. A request
  without a live credential halts with the `unauthenticated` error body.
  """

  @behaviour Plug

  import Plug.Conn

  alias Biot.Server.Credentials
  alias BiotWeb.Api.BearerHeader
  alias BiotWeb.Api.FallbackController

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with {:ok, token} <- conn |> get_req_header("authorization") |> BearerHeader.token(),
         {:ok, authentication} <- Credentials.authenticate(token) do
      assign(conn, :authentication, authentication)
    else
      :error -> conn |> FallbackController.call({:error, :unauthenticated}) |> halt()
    end
  end
end
