defmodule Biot.Server.Schema.Publication do
  @moduledoc "A published biot port and its stable hostname."

  use Ecto.Schema

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.Hostname
  alias Biot.Protocol.Port
  alias Biot.Server.Ecto.ProtocolValue

  @primary_key false
  schema "publications" do
    field(:biot_id, ProtocolValue, module: BiotId, primary_key: true)
    field(:port, ProtocolValue, module: Port, primary_key: true)
    field(:hostname, ProtocolValue, module: Hostname)
    field(:state, Ecto.Enum, values: [:active, :inactive], default: :active)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
