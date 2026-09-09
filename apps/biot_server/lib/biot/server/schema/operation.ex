defmodule Biot.Server.Schema.Operation do
  @moduledoc "The durable outcome of accepted lifecycle work."

  use Ecto.Schema

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.OperationId
  alias Biot.Protocol.PrincipalId
  alias Biot.Server.Ecto.Failure
  alias Biot.Server.Ecto.ProtocolValue

  @kinds [:create, :start, :stop, :update_environment, :destroy]
  @type kind :: :create | :start | :stop | :update_environment | :destroy

  @outcomes [:pending, :working, :succeeded, :failed, :superseded]
  @type outcome :: :pending | :working | :succeeded | :failed | :superseded

  @primary_key false
  schema "operations" do
    field(:id, ProtocolValue, module: OperationId, primary_key: true)
    field(:actor_id, ProtocolValue, module: PrincipalId)
    field(:biot_id, ProtocolValue, module: BiotId)
    field(:kind, Ecto.Enum, values: @kinds)
    field(:target_revision, :integer)
    field(:outcome, Ecto.Enum, values: @outcomes)
    field(:failure, Failure)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
