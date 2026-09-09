defmodule Biot.Server.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [Biot.Server.Repo]
    opts = [strategy: :one_for_one, name: Biot.Server.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
