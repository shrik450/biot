defmodule Biot.Server.Repo.Migrations.CreateCredentials do
  use Ecto.Migration

  def change do
    create table(:credentials, primary_key: false) do
      add(:id, :string, primary_key: true, null: false)

      add(
        :principal_id,
        references(:principals, type: :string, on_delete: :nothing),
        null: false
      )

      add(:label, :string, null: false)
      add(:secret_digest, :string, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:last_used_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:credentials, [:secret_digest], name: :credential_digest))
  end
end
