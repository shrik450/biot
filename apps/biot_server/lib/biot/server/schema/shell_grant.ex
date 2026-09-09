defmodule Biot.Server.Schema.ShellGrant do
  @moduledoc "A principal's explicit shell access to one biot."

  use Ecto.Schema

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.PrincipalId
  alias Biot.Server.Ecto.ProtocolValue

  @primary_key false
  schema "shell_grants" do
    field(:biot_id, ProtocolValue, module: BiotId, primary_key: true)
    field(:principal_id, ProtocolValue, module: PrincipalId, primary_key: true)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
