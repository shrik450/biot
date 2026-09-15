defmodule BiotWeb.Plugs.ControlOrigin do
  @moduledoc """
  Rejects a browser request that can change state when its `Origin` is not the control origin.

  A request without `Origin` passes, so Phoenix's CSRF protection alone decides it. The endpoint's
  configured URL is the one control origin, so the rule never reads the request's own host.
  A rejection raises `ForeignOriginError`, which renders as 403 the same way a CSRF failure does.
  """

  @behaviour Plug

  import Plug.Conn

  defmodule ForeignOriginError do
    defexception message: "the request's Origin is not the control origin", plug_status: 403
  end

  # The same methods that Plug.CSRFProtection leaves unchecked.
  @safe_methods ~w(GET HEAD OPTIONS)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    control_origin = Phoenix.Controller.endpoint_module(conn).url()

    if allowed?(conn.method, get_req_header(conn, "origin"), control_origin),
      do: conn,
      else: raise(ForeignOriginError)
  end

  @doc """
  Decides a request from its method, its `Origin` header values, and the control origin.

  A safe method always passes. Otherwise the request passes with no `Origin` header, or with one
  header equal to the control origin. Two headers never pass, because a browser sends at most one.
  """
  @spec allowed?(String.t(), [String.t()], String.t()) :: boolean()
  def allowed?(method, _origins, _control_origin) when method in @safe_methods, do: true
  def allowed?(_method, [], _control_origin), do: true
  def allowed?(_method, [origin], control_origin), do: origin == control_origin
  def allowed?(_method, _origins, _control_origin), do: false

  @doc """
  Decides a LiveView socket's `Origin` for the socket's `check_origin`.

  Phoenix calls this only when the upgrade request has an `Origin`. Its default rule compares the
  host alone, which would admit another scheme or port on the control host.
  """
  @spec socket_origin?(URI.t()) :: boolean()
  def socket_origin?(origin), do: URI.to_string(origin) == BiotWeb.Endpoint.url()
end
