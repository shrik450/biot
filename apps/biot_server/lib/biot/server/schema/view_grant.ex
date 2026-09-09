defmodule Biot.Server.Schema.ViewGrant do
  @moduledoc "A principal's explicit view access to one published biot port."

  use Ecto.Schema

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.Port
  alias Biot.Protocol.PrincipalId
  alias Biot.Server.Ecto.ProtocolValue

  @primary_key false
  schema "view_grants" do
    field(:biot_id, ProtocolValue, module: BiotId, primary_key: true)
    field(:port, ProtocolValue, module: Port, primary_key: true)
    field(:principal_id, ProtocolValue, module: PrincipalId, primary_key: true)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
