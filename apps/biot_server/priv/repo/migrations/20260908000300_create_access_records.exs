defmodule Biot.Server.Repo.Migrations.CreateAccessRecords do
  use Ecto.Migration

  def up do
    create table(:publications, primary_key: false) do
      add(
        :biot_id,
        references(:biots, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:port, :string, null: false)
      add(:hostname, :string, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:publications, [:biot_id, :port], name: :publication_port))
    create(unique_index(:publications, [:hostname], name: :publication_host))

    create table(:shell_grants, primary_key: false) do
      add(
        :biot_id,
        references(:biots, type: :string, on_delete: :delete_all),
        null: false
      )

      add(
        :principal_id,
        references(:principals, type: :string, on_delete: :delete_all),
        null: false
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:shell_grants, [:biot_id, :principal_id], name: :shell_grant))

    # SQLite requires the composite foreign key inline at table creation.
    execute("""
    CREATE TABLE view_grants (
      biot_id TEXT NOT NULL,
      port TEXT NOT NULL,
      principal_id TEXT NOT NULL REFERENCES principals(id) ON DELETE CASCADE,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      FOREIGN KEY (biot_id, port)
        REFERENCES publications(biot_id, port)
        ON DELETE CASCADE
    )
    """)

    create(
      unique_index(:view_grants, [:biot_id, :port, :principal_id], name: :view_grant)
    )
  end

  def down do
    drop(table(:view_grants))
    drop(table(:shell_grants))
    drop(table(:publications))
  end
end
