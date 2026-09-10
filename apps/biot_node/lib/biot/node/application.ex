defmodule Biot.Node.Application do
  @moduledoc false

  use Application

  require Logger

  alias Biot.Protocol.Wire

  @control_connection_keys [:server_host, :server_port, :registration_id, :tls]
  @host_keys [:data_root, :uid_range_base, :uid_range_count, :uid_range_limit]

  @impl true
  def start(_type, _args) do
    Wire.check_frame_limit!(Application.fetch_env!(:biot_node, :max_frame_bytes))

    children = [Biot.Node.Host.Command.Reaper] ++ host_children()

    opts = [strategy: :one_for_one, name: Biot.Node.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # A node without a data root owns no biots. It has nowhere to keep the intent the server would
  # send it, so it holds no control link either.
  defp host_children do
    if configured?(@host_keys) do
      [
        Biot.Node.DataRootLock,
        Biot.Node.Host.Setup,
        Biot.Node.Repo,
        Biot.Node.Journal.Migrator,
        {Task.Supervisor, name: Biot.Node.Control.RequestSupervisor},
        Biot.Node.RuntimeLogs,
        Biot.Node.Controllers,
        Biot.Node.Host.ContainerEvents
      ] ++ control_connection_child()
    else
      Logger.info("node host disabled because the data root is not configured")
      []
    end
  end

  defp control_connection_child do
    if configured?(@control_connection_keys) do
      [Biot.Node.Control.Connection]
    else
      Logger.info("node control connection disabled because the server is not configured")
      []
    end
  end

  defp configured?(keys) do
    Enum.all?(keys, fn key -> not is_nil(Application.get_env(:biot_node, key)) end)
  end
end
