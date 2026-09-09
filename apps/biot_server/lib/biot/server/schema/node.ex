defmodule Biot.Server.Schema.Node do
  @moduledoc "A durable node registration and its operator-controlled status."

  use Ecto.Schema

  alias Biot.Protocol.NodeId
  alias Biot.Protocol.Platform
  alias Biot.Protocol.RegistrationId
  alias Biot.Server.Ecto.ProtocolValue

  @primary_key false
  schema "nodes" do
    field(:id, ProtocolValue, module: NodeId, primary_key: true)
    field(:registration, ProtocolValue, module: RegistrationId)
    field(:peer_identity, :string)
    field(:status, Ecto.Enum, values: [:enabled, :disabled, :retired, :abandoned])
    field(:platform, ProtocolValue, module: Platform)
    field(:max_biots, :integer)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
