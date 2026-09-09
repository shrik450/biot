defmodule Biot.Server.Control.Listener do
  @moduledoc "Owns the mutually authenticated TLS listener for node control connections."

  @spec start_link(keyword()) :: Supervisor.on_start() | :ignore
  def start_link(options \\ []) do
    port = Keyword.get(options, :port, Application.get_env(:biot_server, :control_port))
    tls = Keyword.get(options, :tls, Application.get_env(:biot_server, :control_tls))

    case {port, tls} do
      {nil, _tls} -> :ignore
      {_port, nil} -> {:error, :control_tls_not_configured}
      {port, tls} -> ThousandIsland.start_link(listener_options(port, tls, options))
    end
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options) do
    %{
      id: Keyword.get(options, :id, __MODULE__),
      start: {__MODULE__, :start_link, [options]},
      type: :supervisor
    }
  end

  defp listener_options(port, tls, options) do
    # Merge server-side peer verification over config so config cannot weaken it.
    transport_options =
      Keyword.merge(tls,
        verify: :verify_peer,
        fail_if_no_peer_cert: true,
        reuseaddr: true
      )

    [
      port: port,
      transport_module: ThousandIsland.Transports.SSL,
      transport_options: transport_options,
      handler_module: Biot.Server.Control.Connection,
      handler_options: Keyword.get(options, :handler_options, []),
      read_timeout: :infinity,
      silent_terminate_on_error: true,
      supervisor_options: Keyword.get(options, :supervisor_options, [])
    ]
  end
end
