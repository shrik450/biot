defmodule Biot.Server.Repo.Migrations.AddPrincipalStatus do
  use Ecto.Migration

  def change do
    alter table(:principals) do
      add(:status, :string, null: false, default: "enabled")
    end
  end
end