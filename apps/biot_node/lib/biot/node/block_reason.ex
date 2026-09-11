defmodule Biot.Node.BlockReason do
  @moduledoc "Why reconciliation has nothing to run for a biot right now."

  alias Biot.Node.Action
  alias Biot.Node.InspectionFailure
  alias Biot.Protocol.Failure
  alias Biot.Protocol.RepositorySource

  @typedoc """
  `fetch_credential` is the one reason that is not the node's to resolve. Unlike a recorded
  failure it costs no retry budget and leaves its operation working, because nothing has gone
  wrong: the biot is waiting for a person.
  """
  @type t ::
          {:inspection, InspectionFailure.t()}
          | {:current_action, Action.t()}
          | {:recorded_failure, Failure.t()}
          | {:fetch_credential, RepositorySource.t()}
end
