defmodule Biot.Server.Schema.PreviewHandoff do
  @moduledoc "A single-use code that lends a control login to one preview host."

  use Ecto.Schema

  alias Biot.Protocol.{Digest, Hostname, SameOriginPath}
  alias Biot.Server.Ecto.ProtocolValue

  @primary_key false
  schema "preview_handoffs" do
    field(:code_digest, ProtocolValue, module: Digest, primary_key: true)
    field(:hostname, ProtocolValue, module: Hostname)
    field(:control_session_digest, ProtocolValue, module: Digest)
    field(:challenge_digest, ProtocolValue, module: Digest)
    field(:return_path, ProtocolValue, module: SameOriginPath)
    field(:expires_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
