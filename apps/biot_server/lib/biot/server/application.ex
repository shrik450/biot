defmodule Biot.Server.Application do
  @moduledoc false

  use Application

  alias Biot.Protocol.Wire

  @impl true
  def start(_type, _args) do
    Wire.check_frame_limit!(Application.fetch_env!(:biot_server, :max_frame_bytes))

    children = [
      Biot.Server.Repo,
      Biot.Server.ExpirySweep,
      {Phoenix.PubSub, name: Biot.Server.PubSub},
      Biot.Server.Principals.Startup,
      Biot.Server.NodeConnections,
      # Startup needs the registry, while the listener must not accept a node before enrollment.
      {Registry, keys: :unique, name: Biot.Server.Control.Registry},
      Biot.Server.Nodes.Startup,
      Biot.Server.Control.Listener
    ]

    opts = [strategy: :one_for_one, name: Biot.Server.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
