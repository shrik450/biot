defmodule Biot.Server.Repo.Migrations.CreateSessions do
  use Ecto.Migration

  def change do
    create table(:sessions, primary_key: false) do
      add(:id_digest, :string, primary_key: true, null: false)

      add(
        :principal_id,
        references(:principals, type: :string, on_delete: :nothing),
        null: false
      )

      # SQLite adds a table check through a column definition; the expression
      # may reference any column in the same row.
      add(:scope, :string,
        null: false,
        check: %{
          name: "sessions_shape_valid",
          expr:
            "(scope = 'control' AND hostname IS NULL AND control_session_digest IS NULL) OR " <>
              "(scope = 'preview' AND hostname IS NOT NULL AND control_session_digest IS NOT NULL)"
        }
      )

      add(:hostname, :string)

      add(
        :control_session_digest,
        references(:sessions, column: :id_digest, type: :string, on_delete: :delete_all)
      )

      add(:expires_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end
  end
end
