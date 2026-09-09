defmodule Biot.Server.Schema.AccessObservation do
  @moduledoc "The assigned node's latest applied access revision for one biot."

  use Ecto.Schema

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.ConnectionId
  alias Biot.Server.Ecto.ProtocolValue

  @primary_key false
  schema "access_observations" do
    field(:biot_id, ProtocolValue, module: BiotId, primary_key: true)
    field(:connection_id, ProtocolValue, module: ConnectionId)
    field(:applied_access_revision, :integer)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
