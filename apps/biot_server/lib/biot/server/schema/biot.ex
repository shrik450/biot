defmodule Biot.Server.Schema.Biot do
  @moduledoc "A durable biot identity with its assignment and current execution intent."

  use Ecto.Schema

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.Desired
  alias Biot.Protocol.Digest
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.NodeId
  alias Biot.Protocol.PrincipalId
  alias Biot.Protocol.RepositorySource
  alias Biot.Server.Ecto.ProtocolValue

  @primary_key false
  schema "biots" do
    field(:id, ProtocolValue, module: BiotId, primary_key: true)
    field(:name, :string)
    field(:owner_id, ProtocolValue, module: PrincipalId)
    field(:node_id, ProtocolValue, module: NodeId)
    field(:repository, ProtocolValue, module: RepositorySource)
    field(:creation_fingerprint, ProtocolValue, module: Digest)
    field(:desired_revision, :integer)
    field(:desired_state, Ecto.Enum, values: Desired.states())
    field(:desired_environment_id, ProtocolValue, module: EnvironmentId)
    field(:access_revision, :integer)
    field(:direct_secret_exposure_possible, :boolean, default: false)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec desired(t()) :: Desired.t()
  def desired(%__MODULE__{} = biot) do
    %Desired{
      revision: biot.desired_revision,
      state: biot.desired_state,
      environment_id: biot.desired_environment_id
    }
  end
end
