defmodule Biot.Server.Repo.Migrations.CreateBiotsAndEnvironments do
  use Ecto.Migration

  def up do
    # SQLite requires the composite foreign key inline at table creation.
    execute("""
    CREATE TABLE biots (
      id TEXT PRIMARY KEY NOT NULL,
      name TEXT NOT NULL,
      owner_id TEXT NOT NULL REFERENCES principals(id),
      node_id TEXT NOT NULL REFERENCES nodes(id),
      repository TEXT NOT NULL,
      creation_fingerprint TEXT NOT NULL,
      desired_revision INTEGER NOT NULL CHECK (desired_revision > 0),
      desired_state TEXT NOT NULL CHECK (desired_state IN ('running', 'stopped', 'destroyed')),
      desired_environment_id TEXT NOT NULL,
      access_revision INTEGER NOT NULL CHECK (access_revision > 0),
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      FOREIGN KEY (desired_environment_id, id)
        REFERENCES environments(id, biot_id)
        DEFERRABLE INITIALLY DEFERRED
    )
    """)

    create(
      unique_index(:biots, [:owner_id, :name],
        name: :live_biot_name,
        where: "desired_state <> 'destroyed'"
      )
    )

    create table(:environments, primary_key: false) do
      add(:id, :string, primary_key: true, null: false)

      add(
        :biot_id,
        references(:biots, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:selection, :map, null: false)
      add(:resolution, :map, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:environments, [:id, :biot_id], name: :environment_owner))
  end

  def down do
    drop(table(:environments))
    drop(table(:biots))
  end
end
