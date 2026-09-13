defmodule Biot.Server.Schema.Session do
  @moduledoc "A browser login: a control session or a preview of one."

  use Ecto.Schema

  alias Biot.Protocol.{Digest, Hostname, PrincipalId}
  alias Biot.Server.Ecto.ProtocolValue

  @primary_key false
  schema "sessions" do
    field(:id_digest, ProtocolValue, module: Digest, primary_key: true)
    field(:principal_id, ProtocolValue, module: PrincipalId)
    field(:scope, Ecto.Enum, values: [:control, :preview])
    field(:hostname, ProtocolValue, module: Hostname)
    field(:control_session_digest, ProtocolValue, module: Digest)
    field(:expires_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
