defmodule Biot.Node.Repo.Migrations.AddRetryWaitingFor do
  use Ecto.Migration

  def change do
    alter table(:retry_states) do
      add(:waiting_for, :map)
    end
  end
end
