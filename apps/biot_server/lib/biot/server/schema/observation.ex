defmodule Biot.Server.Schema.Observation do
  @moduledoc "The assigned node's latest report for one biot."

  use Ecto.Schema

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.ConnectionId
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.ExecutionReport
  alias Biot.Server.Ecto.ObservationContainer
  alias Biot.Server.Ecto.ObservationFailure
  alias Biot.Server.Ecto.ProtocolValue

  @primary_key false
  schema "observations" do
    field(:biot_id, ProtocolValue, module: BiotId, primary_key: true)
    field(:connection_id, ProtocolValue, module: ConnectionId)
    field(:received_at, :utc_datetime_usec)
    field(:accepted_revision, :integer)
    field(:installed_environment_id, ProtocolValue, module: EnvironmentId)
    field(:container, ObservationContainer)

    field(:data, Ecto.Enum, values: ExecutionReport.data_states())

    field(:failure, ObservationFailure)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
