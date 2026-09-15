defmodule Biot.Node.Journal.Migrator do
  @moduledoc """
  Brings a journal to the current schema before anything reads it.

  The migrations are compiled modules rather than files under `priv`. A node migrates the journal
  of whichever data root it is given, and the tests start many journals in one VM; compiled
  modules load once, where migration files would be compiled again for every journal.
  """

  alias Biot.Node.Journal.Migrations
  alias Biot.Node.Repo

  @migrations [
    {20_260_909_000_100, Migrations.CreateNodeJournal},
    {20_260_911_000_100, Migrations.AddRetryWaitingFor},
    {20_260_915_000_100, Migrations.RemoveResolutionSnapshotPath}
  ]

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
    migrate()
    :ignore
  end

  @doc "Runs every pending migration against the running `Biot.Node.Repo`."
  @spec migrate(keyword()) :: [pos_integer()]
  def migrate(options \\ []) do
    Ecto.Migrator.run(Repo, @migrations, :up, Keyword.put(options, :all, true))
  end
end
