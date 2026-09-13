defmodule Biot.Server.Repo.Migrations.CreatePreviewHandoffs do
  use Ecto.Migration

  def change do
    create table(:preview_handoffs, primary_key: false) do
      add(:code_digest, :string, primary_key: true, null: false)
      add(:hostname, :string, null: false)

      add(
        :control_session_digest,
        references(:sessions, column: :id_digest, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:challenge_digest, :string, null: false)
      add(:return_path, :string, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end
  end
end
