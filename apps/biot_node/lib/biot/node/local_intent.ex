defmodule Biot.Node.LocalIntent do
  @moduledoc """
  The last BiotSpec the node accepted for one biot, and the final report of a destruction the node
  has already finished. It is the durable intent a restarted controller converges from, so it never
  depends on remembered process state.

  A `destruction_report` is a receipt rather than intent: the biot's controller has exited, and the
  node keeps replaying that report until the server stops sending intent for the biot.
  """

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.BiotSpec
  alias Biot.Protocol.ExecutionReport

  @enforce_keys [:biot_id, :biot_spec, :destruction_report]
  defstruct [:biot_id, :biot_spec, :destruction_report]

  @type t :: %__MODULE__{
          biot_id: BiotId.t(),
          biot_spec: BiotSpec.t(),
          destruction_report: ExecutionReport.t() | nil
        }
end
