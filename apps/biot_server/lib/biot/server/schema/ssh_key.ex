defmodule Biot.Server.Schema.SshKey do
  @moduledoc "A registered SSH public key held by one principal."

  use Ecto.Schema

  alias Biot.Protocol.{PrincipalId, SshKeyId, SshPublicKey}
  alias Biot.Server.Ecto.ProtocolValue

  @primary_key false
  schema "ssh_keys" do
    field(:id, ProtocolValue, module: SshKeyId, primary_key: true)
    field(:principal_id, ProtocolValue, module: PrincipalId)
    field(:public_key, ProtocolValue, module: SshPublicKey)
    field(:fingerprint, :string)
    field(:label, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
