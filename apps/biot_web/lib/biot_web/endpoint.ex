defmodule BiotWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :biot_web

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [
      check_origin: {BiotWeb.Plugs.ControlOrigin, :socket_origin?, []},
      connect_info: [
        :peer_data,
        :x_headers,
        :uri,
        session: {BiotWeb.Cookies, :session_options, []}
      ]
    ],
    longpoll: [
      check_origin: {BiotWeb.Plugs.ControlOrigin, :socket_origin?, []},
      connect_info: [
        :peer_data,
        :x_headers,
        :uri,
        session: {BiotWeb.Cookies, :session_options, []}
      ]
    ]

  plug Plug.Static,
    at: "/",
    from: :biot_web,
    gzip: not code_reloading?,
    only: BiotWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  # Before telemetry, so request logs and metrics see the client rather than the edge.
  plug :put_client_address
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug :session
  plug BiotWeb.Router

  defp put_client_address(conn, _opts) do
    trusted = Application.fetch_env!(:biot_web, :trusted_edge_peers)
    forwarded = get_req_header(conn, "x-forwarded-for")
    %{conn | remote_ip: BiotWeb.ClientAddress.resolve(conn.remote_ip, trusted, forwarded)}
  end

  # The cookie's max_age comes from runtime configuration, so the options are built per request
  # rather than when the endpoint compiles.
  defp session(conn, _opts) do
    Plug.Session.call(conn, Plug.Session.init(BiotWeb.Cookies.session_options()))
  end
end
