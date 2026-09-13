defmodule Biot.Server.Schema.Principal do
  @moduledoc "The durable identity last seen through the configured OIDC provider."

  use Ecto.Schema

  alias Biot.Protocol.PrincipalId
  alias Biot.Server.Ecto.ProtocolValue

  @primary_key false
  schema "principals" do
    field(:id, ProtocolValue, module: PrincipalId, primary_key: true)
    field(:issuer, :string)
    field(:subject, :string)
    field(:last_seen_email, :string)
    field(:last_seen_name, :string)
    field(:status, Ecto.Enum, values: [:enabled, :disabled], default: :enabled)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
