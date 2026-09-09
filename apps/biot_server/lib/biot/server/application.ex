defmodule Biot.Server.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Biot.Server.Repo,
      {Phoenix.PubSub, name: Biot.Server.PubSub},
      Biot.Server.NodeConnections,
      Biot.Server.Nodes.Startup,
      {Registry, keys: :unique, name: Biot.Server.Control.Registry},
      Biot.Server.Control.Listener
    ]

    opts = [strategy: :one_for_one, name: Biot.Server.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
