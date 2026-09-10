defmodule Biot.Node.Journal.Schema.Allocation do
  @moduledoc "The journal row for one owned allocation."

  use Ecto.Schema

  alias Biot.Node.Journal.Ecto.ParsedValue
  alias Biot.Node.NetworkId
  alias Biot.Node.NodePrivatePath
  alias Biot.Protocol.BiotId

  @primary_key false
  schema "allocations" do
    field(:biot_id, ParsedValue, module: BiotId, primary_key: true)
    field(:uid_start, :integer)
    field(:uid_count, :integer)
    field(:data_root, ParsedValue, module: NodePrivatePath)
    field(:network_id, ParsedValue, module: NetworkId)
    field(:initialized, :boolean)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
