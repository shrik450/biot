defmodule Biot.Node.Application do
  @moduledoc false

  use Application

  require Logger

  @control_connection_keys [:server_host, :server_port, :registration_id, :tls]

  @impl true
  def start(_type, _args) do
    children =
      [
        {Registry, keys: :duplicate, name: Biot.Node.Intents.Registry},
        Biot.Node.Intents,
        Biot.Node.Diagnostics
      ] ++ control_connection_child()

    opts = [strategy: :one_for_one, name: Biot.Node.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp control_connection_child do
    if control_connection_configured?() do
      [Biot.Node.Control.Connection]
    else
      Logger.info("node control connection disabled because the node is not configured")
      []
    end
  end

  defp control_connection_configured? do
    Enum.all?(@control_connection_keys, fn key ->
      not is_nil(Application.get_env(:biot_node, key))
    end)
  end
end
