defmodule Biot.Server.Migrator do
  @moduledoc """
  Brings the database to the current schema at boot, before any child reads it.

  The server is its database's only writer and SQLite keeps it in one file, so migrating at boot
  cannot race another instance, and a release needs no separate migration command.
  """

  alias Biot.Server.Repo

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
    path = Application.app_dir(:biot_server, "priv/repo/migrations")
    Ecto.Migrator.run(Repo, path, :up, all: true)
    :ignore
  end
end
