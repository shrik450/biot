defmodule BiotWeb.Plugs.HostDispatch do
  @moduledoc """
  Routes one request by its `Host` before the router runs.

  A host equal to the control host continues through the endpoint as the app. A host exactly one
  label under the publication domain is a preview request and is answered entirely by
  `BiotWeb.Preview.Proxy`. Anything else gets the not-found page and never reaches the app.
  """

  @behaviour Plug

  alias Biot.Server.DomainName
  alias BiotWeb.Preview.Proxy

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(conn, _options) do
    control_host = Application.fetch_env!(:biot_server, :control_host)
    publication_domain = Application.fetch_env!(:biot_server, :publication_domain)

    case DomainName.classify(conn.host, control_host, publication_domain) do
      :control -> conn
      {:preview, hostname} -> Proxy.call(conn, hostname)
      :unknown -> Proxy.unknown_host(conn)
    end
  end
end
