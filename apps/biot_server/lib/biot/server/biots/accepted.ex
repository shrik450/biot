defmodule Biot.Server.Biots.Accepted do
  @moduledoc "A committed lifecycle change with asynchronous work to track."

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.OperationId

  @enforce_keys [:operation_id, :biot_id, :revision]
  defstruct [:operation_id, :biot_id, :revision]

  @type t :: %__MODULE__{
          operation_id: OperationId.t(),
          biot_id: BiotId.t(),
          revision: pos_integer()
        }
end
