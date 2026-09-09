defmodule Biot.Server.Repo.Migrations.CreatePrincipalsAndNodes do
  use Ecto.Migration

  def change do
    create table(:principals, primary_key: false) do
      add(:id, :string, primary_key: true, null: false)
      add(:issuer, :string, null: false)
      add(:subject, :string, null: false)
      add(:last_seen_email, :string)
      add(:last_seen_name, :string)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:principals, [:issuer, :subject], name: :principal_identity))

    create table(:nodes, primary_key: false) do
      add(:id, :string, primary_key: true, null: false)
      add(:registration, :string, null: false)
      add(:peer_identity, :string, null: false)
      add(:status, :string,
        null: false,
        check: %{
          name: "nodes_status_valid",
          expr: "status IN ('enabled', 'disabled', 'retired', 'abandoned')"
        }
      )

      add(:platform, :string)

      add(:max_biots, :integer,
        null: false,
        check: %{name: "nodes_max_biots_positive", expr: "max_biots > 0"}
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:nodes, [:registration], name: :node_registration))
    create(unique_index(:nodes, [:peer_identity], name: :node_peer_identity))
  end
end
