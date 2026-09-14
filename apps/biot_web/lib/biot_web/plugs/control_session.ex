defmodule BiotWeb.Plugs.ControlSession do
  @moduledoc """
  Authenticates a browser request by the control session token in the Phoenix session and assigns
  `:authentication`.

  `:authentication` is nil when the session holds no token, or holds a token whose login has
  ended. The plug removes an ended token from the session, so the response stops carrying it.
  """

  @behaviour Plug

  import Plug.Conn

  alias Biot.Server.Sessions

  @token_key "token"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts), do: authenticate(conn, token(conn))

  @doc """
  Reads the control session token from the Phoenix session.

  After this plug runs, the token is present only when its login is live.
  """
  @spec token(Plug.Conn.t()) :: String.t() | nil
  def token(conn), do: get_session(conn, @token_key)

  defp authenticate(conn, nil), do: assign(conn, :authentication, nil)

  defp authenticate(conn, token) do
    case Sessions.control(token) do
      {:ok, authentication} -> assign(conn, :authentication, authentication)
      :error -> conn |> delete_session(@token_key) |> assign(:authentication, nil)
    end
  end
end
