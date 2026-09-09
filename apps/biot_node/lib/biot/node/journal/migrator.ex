defmodule Biot.Node.Journal.Migrator do
  @moduledoc false

  alias Biot.Node.Repo

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [options]},
      restart: :temporary
    }
  end

  @spec start_link(keyword()) :: :ignore
  def start_link(_options \\ []) do
    path = Application.app_dir(:biot_node, "priv/repo/migrations")
    Ecto.Migrator.run(Repo, path, :up, all: true)
    :ignore
  end
end
