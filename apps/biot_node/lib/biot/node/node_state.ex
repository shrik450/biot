defmodule Biot.Node.NodeState do
  @moduledoc """
  The one derived view reconciliation reads for a single biot: recorded ownership joined with host
  inspection, so the pure core sees product states such as `lost` instead of two copies of one
  resource.

  `pending_exit` holds the exit of a container the biot still wants running. The controller sets it
  when inspection first sees that exit, and clears it only after it records the failure
  reconciliation returns for it. That invariant is what lets the core retire the exited container
  first and report the exit once absence is observed.
  """

  alias Biot.Node.Allocation
  alias Biot.Node.ArtifactId
  alias Biot.Node.InspectionFailure
  alias Biot.Node.Installation
  alias Biot.Node.MarkerId
  alias Biot.Node.Resolution
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.ContainerState
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.Failure
  alias Biot.Protocol.IncarnationId

  @typedoc "An inspected host resource. `unknown` blocks only the decisions that need this fact."
  @type resource(value) :: :absent | {:unknown, InspectionFailure.t()} | {:present, value}

  @typedoc """
  The container's own account of the biot that owns it and the environment it runs. `biot_id` is
  provenance the node reads back from the container, so a container another biot owns is a visible
  failure rather than something this biot may remove.
  """
  @type container :: %{
          incarnation_id: IncarnationId.t(),
          biot_id: BiotId.t(),
          environment_id: EnvironmentId.t(),
          state: ContainerState.t()
        }

  @type data_state ::
          :no_allocation
          | {:unknown, Allocation.t(), InspectionFailure.t()}
          | {:uninitialized, Allocation.t()}
          | {:present, Allocation.t(), MarkerId.t()}
          | {:lost, Allocation.t()}

  @type installation_state ::
          nil
          | {:unknown, Installation.t(), InspectionFailure.t()}
          | {:present, Installation.t()}
          | {:lost, Installation.t()}

  @typedoc "One recorded resolution. An environment with no entry in `resolutions` is unresolved."
  @type resolution_state ::
          {:unknown, Resolution.t(), InspectionFailure.t()}
          | {:present, Resolution.t()}
          | {:lost, Resolution.t()}

  @typedoc "The exit of a container the biot still wants running, until the controller records it."
  @type pending_exit :: nil | %{incarnation_id: IncarnationId.t(), exit_status: non_neg_integer()}

  @typedoc "The failure recorded for one desired revision. The controller clears it after an action succeeds."
  @type recorded_failure :: nil | {pos_integer(), Failure.t()}

  @enforce_keys [
    :data,
    :resolutions,
    :installation,
    :container,
    :prepared,
    :pending_exit,
    :failure
  ]
  defstruct [:data, :resolutions, :installation, :container, :prepared, :pending_exit, :failure]

  @typedoc "`resolutions` and `prepared` hold only this biot's environments, keyed by environment."
  @type t :: %__MODULE__{
          data: data_state(),
          resolutions: %{EnvironmentId.t() => resolution_state()},
          installation: installation_state(),
          container: resource(container()),
          prepared: resource(%{EnvironmentId.t() => ArtifactId.t()}),
          pending_exit: pending_exit(),
          failure: recorded_failure()
        }
end
