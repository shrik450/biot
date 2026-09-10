defmodule Biot.Node.Repo.Migrations.CreateNodeJournal do
  use Ecto.Migration

  def change do
    create table(:allocations, primary_key: false) do
      add(:biot_id, :string, primary_key: true, null: false)
      add(:uid_start, :integer, null: false)

      add(:uid_count, :integer,
        null: false,
        check: %{name: "allocations_uid_count_positive", expr: "uid_count > 0"}
      )

      add(:data_root, :string, null: false)
      add(:network_id, :string, null: false)
      add(:initialized, :boolean, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    # One configured range size and unique starts keep ranges disjoint during concurrent inserts.
    create(unique_index(:allocations, [:uid_start], name: :allocation_uid_start))
    create(unique_index(:allocations, [:data_root], name: :allocation_data_root))
    create(unique_index(:allocations, [:network_id], name: :allocation_network))

    create table(:installations, primary_key: false) do
      add(
        :biot_id,
        references(:allocations, column: :biot_id, type: :string, on_delete: :restrict),
        primary_key: true,
        null: false
      )

      add(:environment_id, :string, null: false)
      add(:artifact_id, :string, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create table(:resolutions, primary_key: false) do
      add(:environment_id, :string, primary_key: true, null: false)

      add(
        :biot_id,
        references(:allocations, column: :biot_id, type: :string, on_delete: :restrict),
        null: false
      )

      add(:manifest, :map, null: false)
      add(:snapshot_path, :string)

      timestamps(type: :utc_datetime_usec)
    end

    create table(:local_intents, primary_key: false) do
      add(:biot_id, :string, primary_key: true, null: false)
      add(:biot_spec, :map, null: false)
      add(:destruction_report, :map)

      timestamps(type: :utc_datetime_usec)
    end

    # A retry row outlives its allocation while a destruction runs, and it goes with the local
    # intent rather than with any resource, so the biot ID is the whole key.
    create table(:retry_states, primary_key: false) do
      add(:biot_id, :string, primary_key: true, null: false)

      add(:target_revision, :integer,
        null: false,
        check: %{name: "retry_states_target_revision_positive", expr: "target_revision > 0"}
      )

      add(:attempts, :map, null: false)
      add(:next_attempt_at, :utc_datetime_usec)
      add(:failure, :map)

      timestamps(type: :utc_datetime_usec)
    end
  end
end
