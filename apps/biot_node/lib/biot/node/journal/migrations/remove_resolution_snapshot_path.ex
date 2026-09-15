defmodule Biot.Node.Journal.Migrations.RemoveResolutionSnapshotPath do
  @moduledoc false

  use Ecto.Migration

  def change do
    alter table(:resolutions) do
      remove(:snapshot_path, :string)
    end
  end
end
