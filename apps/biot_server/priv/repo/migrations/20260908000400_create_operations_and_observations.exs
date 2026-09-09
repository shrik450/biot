defmodule Biot.Server.Repo.Migrations.CreateOperationsAndObservations do
  use Ecto.Migration

  def change do
    create table(:operations, primary_key: false) do
      add(:id, :string, primary_key: true, null: false)
      add(:actor_id, references(:principals, type: :string), null: false)

      add(
        :biot_id,
        references(:biots, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:kind, :string,
        null: false,
        check: %{
          name: "operations_kind_valid",
          expr: "kind IN ('create', 'start', 'stop', 'update_environment', 'destroy')"
        }
      )

      add(:target_revision, :integer,
        null: false,
        check: %{
          name: "operations_target_revision_positive",
          expr: "target_revision > 0"
        }
      )

      add(:outcome, :string,
        null: false,
        check: %{
          name: "operations_outcome_valid",
          expr: "outcome IN ('pending', 'working', 'succeeded', 'failed', 'superseded')"
        }
      )

      add(:failure, :map,
        check: %{
          name: "operations_failure_matches_outcome",
          expr:
            "(outcome = 'failed' AND failure IS NOT NULL) OR " <>
              "(outcome <> 'failed' AND failure IS NULL)"
        }
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:operations, [:biot_id, :target_revision], name: :operation_revision))

    create table(:observations, primary_key: false) do
      add(
        :biot_id,
        references(:biots, type: :string, on_delete: :delete_all),
        primary_key: true,
        null: false
      )

      add(:connection_id, :string, null: false)
      add(:received_at, :utc_datetime_usec, null: false)
      add(:accepted_revision, :integer,
        null: false,
        check: %{
          name: "observations_accepted_revision_positive",
          expr: "accepted_revision > 0"
        }
      )

      add(
        :installed_environment_id,
        references(:environments,
          column: :id,
          type: :string,
          with: [biot_id: :biot_id]
        )
      )

      add(:container, :map, null: false)
      add(:data, :string,
        null: false,
        check: %{
          name: "observations_data_valid",
          expr: "data IN ('no_allocation', 'unknown', 'uninitialized', 'present', 'lost')"
        }
      )

      add(:failure, :map)

      timestamps(type: :utc_datetime_usec)
    end

    create table(:node_observations, primary_key: false) do
      add(
        :node_id,
        references(:nodes, type: :string, on_delete: :delete_all),
        primary_key: true,
        null: false
      )

      add(:connection_id, :string, null: false)
      add(:received_at, :utc_datetime_usec, null: false)
      add(:orphaned_allocations, :map, null: false)

      timestamps(type: :utc_datetime_usec)
    end
  end
end
