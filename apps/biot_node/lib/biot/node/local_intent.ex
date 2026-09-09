defmodule Biot.Node.LocalIntent do
  @moduledoc """
  The last BiotSpec the node accepted for one biot. It is the durable intent a restarted
  controller converges from, so it never depends on remembered process state.
  """

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.BiotSpec

  @enforce_keys [:biot_id, :biot_spec]
  defstruct [:biot_id, :biot_spec]

  @type t :: %__MODULE__{biot_id: BiotId.t(), biot_spec: BiotSpec.t()}
end
