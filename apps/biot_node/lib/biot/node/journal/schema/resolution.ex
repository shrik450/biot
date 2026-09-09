defmodule Biot.Node.Journal.Schema.Resolution do
  @moduledoc "The journal row for one Biot-owned environment resolution."

  use Ecto.Schema

  alias Biot.Node.Journal.Ecto.Manifest
  alias Biot.Node.Journal.Ecto.ParsedValue
  alias Biot.Node.NodePrivatePath
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.EnvironmentId

  @primary_key false
  schema "resolutions" do
    field(:environment_id, ParsedValue, module: EnvironmentId, primary_key: true)
    field(:biot_id, ParsedValue, module: BiotId)
    field(:manifest, Manifest)
    field(:snapshot_path, ParsedValue, module: NodePrivatePath)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
