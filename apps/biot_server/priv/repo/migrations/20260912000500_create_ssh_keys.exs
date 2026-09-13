defmodule Biot.Server.Repo.Migrations.CreateSshKeys do
  use Ecto.Migration

  def change do
    create table(:ssh_keys, primary_key: false) do
      add(:id, :string, primary_key: true, null: false)

      add(
        :principal_id,
        references(:principals, type: :string, on_delete: :nothing),
        null: false
      )

      add(:public_key, :string, null: false)
      add(:fingerprint, :string, null: false)
      add(:label, :string, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:ssh_keys, [:fingerprint], name: :ssh_key_fingerprint))
  end
end
