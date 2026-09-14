defmodule BiotWeb.SessionController do
  use BiotWeb, :controller

  alias Biot.Server.Sessions
  alias BiotWeb.Plugs.ControlSession

  @doc """
  Ends this browser's control login, with its preview sessions and handoffs, and clears the session.

  Other logins and the principal's credentials stay valid.
  """
  def logout(conn, _params) do
    # Without a token there is no live login to end. A login that expired after the plug read it
    # is already over, so `Sessions.logout/1` returning `unauthenticated` needs no other response.
    if token = ControlSession.token(conn), do: Sessions.logout(token)

    conn
    |> clear_session()
    |> redirect(to: "/")
  end
end
