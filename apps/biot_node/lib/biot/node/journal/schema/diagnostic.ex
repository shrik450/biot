defmodule Biot.Node.Journal.Schema.Diagnostic do
  @moduledoc "The journal index row for one node-held diagnostic file."

  use Ecto.Schema

  alias Biot.Node.Journal.Ecto.ParsedValue
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.PrivateDiagnosticId

  @primary_key false
  schema "diagnostics" do
    field(:diagnostic_id, ParsedValue, module: PrivateDiagnosticId, primary_key: true)
    field(:biot_id, ParsedValue, module: BiotId)
    field(:revision, :integer)
    field(:stage, :string)
    field(:truncated, :boolean)
    field(:sequence, :integer)
  end

  @type t :: %__MODULE__{}
end
