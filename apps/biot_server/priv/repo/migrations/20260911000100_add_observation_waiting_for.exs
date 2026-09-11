defmodule Biot.Server.Repo.Migrations.AddObservationWaitingFor do
  use Ecto.Migration

  def change do
    alter table(:observations) do
      add(:waiting_for, :map)
    end
  end
end
