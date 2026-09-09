defmodule Biot.Server.Repo.Migrations.CreateAccessObservations do
  use Ecto.Migration

  def change do
    create table(:access_observations, primary_key: false) do
      add(
        :biot_id,
        references(:biots, type: :string, on_delete: :delete_all),
        primary_key: true,
        null: false
      )

      add(:connection_id, :string, null: false)

      add(:applied_access_revision, :integer,
        null: false,
        check: %{
          name: "access_observations_applied_revision_positive",
          expr: "applied_access_revision > 0"
        }
      )

      timestamps(type: :utc_datetime_usec)
    end
  end
end
