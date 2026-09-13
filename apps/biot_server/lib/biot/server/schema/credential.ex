defmodule Biot.Server.Schema.Credential do
  @moduledoc "A labeled bearer credential. Only the token digest is stored."

  use Ecto.Schema

  alias Biot.Protocol.{CredentialId, Digest, PrincipalId}
  alias Biot.Server.Ecto.ProtocolValue

  @primary_key false
  schema "credentials" do
    field(:id, ProtocolValue, module: CredentialId, primary_key: true)
    field(:principal_id, ProtocolValue, module: PrincipalId)
    field(:label, :string)
    field(:secret_digest, ProtocolValue, module: Digest)
    field(:expires_at, :utc_datetime_usec)
    field(:last_used_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
