defmodule Biot.Server.Biots.Unchanged do
  @moduledoc "A lifecycle request that matches the current intent."

  alias Biot.Protocol.BiotId

  @enforce_keys [:biot_id, :revision]
  defstruct [:biot_id, :revision]

  @type t :: %__MODULE__{biot_id: BiotId.t(), revision: pos_integer()}
end
