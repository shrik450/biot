defmodule Biot.Node.Journal.Schema.LocalIntent do
  @moduledoc "The journal row for the last accepted BiotSpec."

  use Ecto.Schema

  alias Biot.Node.Journal.Ecto.BiotSpec
  alias Biot.Node.Journal.Ecto.ParsedValue
  alias Biot.Protocol.BiotId

  @primary_key false
  schema "local_intents" do
    field(:biot_id, ParsedValue, module: BiotId, primary_key: true)
    field(:biot_spec, BiotSpec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
