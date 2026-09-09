defmodule Biot.Node.Journal.Schema.Installation do
  @moduledoc "The journal row for one allocation's installed artifact."

  use Ecto.Schema

  alias Biot.Node.ArtifactId
  alias Biot.Node.Journal.Ecto.ParsedValue
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.EnvironmentId

  @primary_key false
  schema "installations" do
    field(:biot_id, ParsedValue, module: BiotId, primary_key: true)
    field(:environment_id, ParsedValue, module: EnvironmentId)
    field(:artifact_id, ParsedValue, module: ArtifactId)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
