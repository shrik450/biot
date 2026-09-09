defmodule Biot.Server.Schema.NodeObservation do
  @moduledoc "The latest node-level report, including allocations unknown to the server."

  use Ecto.Schema

  alias Biot.Protocol.NodeId
  alias Biot.Server.Ecto.OrphanedAllocations
  alias Biot.Server.Ecto.ProtocolValue

  @primary_key false
  schema "node_observations" do
    field(:node_id, ProtocolValue, module: NodeId, primary_key: true)
    field(:connection_id, :string)
    field(:received_at, :utc_datetime_usec)
    field(:orphaned_allocations, OrphanedAllocations)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
