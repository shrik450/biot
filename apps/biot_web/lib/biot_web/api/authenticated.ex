defmodule BiotWeb.Api.Authenticated do
  @moduledoc """
  Reads who an API request authenticated as.

  The `BiotWeb.Api.Bearer` plug assigns `:authentication` before any API action runs, so every
  action can read the actor from it.
  """

  alias Biot.Server.Actor

  @spec actor(Plug.Conn.t()) :: Actor.t()
  def actor(conn), do: conn.assigns.authentication.actor
end
