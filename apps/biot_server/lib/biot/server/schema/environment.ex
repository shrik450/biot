defmodule Biot.Server.Schema.Environment do
  @moduledoc "A biot-owned environment selection and its atomic resolution."

  use Ecto.Schema

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.EnvironmentId
  alias Biot.Server.Ecto.EnvironmentResolution
  alias Biot.Server.Ecto.EnvironmentSelection
  alias Biot.Server.Ecto.ProtocolValue

  @primary_key false
  schema "environments" do
    field(:id, ProtocolValue, module: EnvironmentId, primary_key: true)
    field(:biot_id, ProtocolValue, module: BiotId)
    field(:selection, EnvironmentSelection)
    field(:resolution, EnvironmentResolution)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
