defmodule Biot.Protocol.Failure do
  @moduledoc "A bounded description of a failed node lifecycle action."

  alias Biot.Protocol.PrivateDiagnosticId

  @enforce_keys [:stage, :code, :retry, :message, :diagnostic_ref]
  defstruct [:stage, :code, :retry, :message, :diagnostic_ref]

  @type stage ::
          :allocate
          | :initialize
          | :resolve
          | :prepare
          | :install
          | :start
          | :retire
          | :remove_data
          | :release_allocation
          | :inspect
  @type code ::
          :resource_unavailable
          | :invalid_source
          | :resolution_failed
          | :preparation_failed
          | :installation_failed
          | :container_failed
          | :lost_data
          | :inspection_failed
  @type retry_policy :: :automatic | :after_change | :operator
  @type t :: %__MODULE__{
          stage: stage(),
          code: code(),
          retry: retry_policy(),
          message: String.t(),
          diagnostic_ref: PrivateDiagnosticId.t() | nil
        }
end
