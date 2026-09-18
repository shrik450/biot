defmodule BiotWeb.Plugs.Health do
  @moduledoc """
  Answers the health check before host dispatch, the session, and the router.

  A container runtime calls the listener on loopback with no session, no bearer token, and a `Host`
  of its own choosing, which `BiotWeb.Plugs.HostDispatch` would otherwise call an unknown host. So
  this plug answers `GET /health` on the control host and on every host outside the publication
  domain. A preview host is left alone, so a published service keeps answering its own `/health`.
  """

  @behaviour Plug

  import Plug.Conn

  alias Biot.Server.DomainName
  alias Biot.Server.Health

  @path "/health"

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(conn, _options) do
    if health_request?(conn), do: respond(conn), else: conn
  end

  defp respond(conn) do
    result = Health.check()

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status(result), Jason.encode!(%{status: status_text(result)}))
    |> halt()
  end

  defp health_request?(conn) do
    conn.method == "GET" and conn.request_path == @path and not preview_host?(conn.host)
  end

  defp preview_host?(host) do
    control_host = Application.fetch_env!(:biot_server, :control_host)
    publication_domain = Application.fetch_env!(:biot_server, :publication_domain)

    match?({:preview, _hostname}, DomainName.classify(host, control_host, publication_domain))
  end

  defp status(:ok), do: 200
  defp status({:error, _reason}), do: 503

  defp status_text(:ok), do: "ok"
  defp status_text({:error, _reason}), do: "unavailable"
end
