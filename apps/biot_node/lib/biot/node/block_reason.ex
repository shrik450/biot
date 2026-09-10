defmodule Biot.Node.BlockReason do
  @moduledoc "Why reconciliation has nothing to run for a biot right now."

  alias Biot.Node.Action
  alias Biot.Node.InspectionFailure
  alias Biot.Protocol.Failure

  @type t ::
          {:inspection, InspectionFailure.t()}
          | {:current_action, Action.t()}
          | {:recorded_failure, Failure.t()}
end
