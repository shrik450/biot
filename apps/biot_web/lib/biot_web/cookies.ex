defmodule BiotWeb.Cookies do
  @moduledoc """
  Names every Biot cookie and holds the attributes they share.

  Every name has the `__Host-` prefix. A browser keeps such a cookie only when it is `Secure`,
  has path `/`, and has no `Domain`, so a preview application on another host cannot set or read
  it.
  """

  alias Biot.Server.Sessions

  @session_name "__Host-biot_session"
  @login_name "__Host-biot_login"
  @preview_name "__Host-biot_preview"
  @handoff_name "__Host-biot_handoff"
  @login_max_age 10 * 60
  @handoff_max_age 5 * 60
  @attributes [secure: true, http_only: true, same_site: "Lax", path: "/"]

  @spec session_name() :: String.t()
  def session_name, do: @session_name

  @spec login_name() :: String.t()
  def login_name, do: @login_name

  @spec preview_name() :: String.t()
  def preview_name, do: @preview_name

  @spec handoff_name() :: String.t()
  def handoff_name, do: @handoff_name

  @spec login_max_age() :: pos_integer()
  def login_max_age, do: @login_max_age

  @doc "Options for the sealed, short-lived OIDC login cookie."
  @spec login_options() :: keyword()
  def login_options, do: [max_age: login_max_age()] ++ @attributes

  @doc """
  Options for the Phoenix session cookie, which is the control login cookie.

  The session holds only the control session token and the CSRF token. The cookie's `max_age` is
  the control session lifetime, so the cookie lasts as long as its session row instead of ending
  when the browser closes. The endpoint and the `/live` socket both read these options, so they
  always agree.
  """
  @spec session_options() :: keyword()
  def session_options do
    [
      store: :cookie,
      key: session_name(),
      signing_salt: "QGKrtdlg",
      max_age: div(Sessions.control_lifetime_ms(), 1000)
    ] ++ @attributes
  end

  @doc "Options for the preview session cookie, which lasts as long as its parent login."
  @spec preview_options() :: keyword()
  def preview_options do
    [max_age: div(Sessions.control_lifetime_ms(), 1000)] ++ @attributes
  end

  @doc "Options for the short-lived preview handoff challenge cookie."
  @spec handoff_options() :: keyword()
  def handoff_options, do: [max_age: @handoff_max_age] ++ @attributes
end
