defmodule Biot.Node.Journal.Migrations.AddRetryWaitingFor do
  @moduledoc false

  use Ecto.Migration

  def change do
    alter table(:retry_states) do
      add(:waiting_for, :map)
    end
  end
end
