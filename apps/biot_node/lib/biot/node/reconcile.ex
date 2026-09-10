defmodule Biot.Node.Reconcile do
  @moduledoc """
  Decides the one thing a biot's controller should do next, from server intent and one derived view
  of inspected host state. It never inspects, re-validates, or talks to Podman, Nix, the
  filesystem, or the server.

  Ordinary intent settles the resources in ownership order; a destruction gives them back in the
  reverse order. Each step answers `:ready` when it has nothing to do, so the first step with work
  wins and the biot is settled only when every step is ready.

      running or stopped:  data -> environment -> execution -> release
      destroyed:           execution -> release -> data
  """

  alias Biot.Node.Action
  alias Biot.Node.BlockReason
  alias Biot.Node.NodeState
  alias Biot.Node.Reconcile.Data
  alias Biot.Node.Reconcile.Environment
  alias Biot.Node.Reconcile.Execution
  alias Biot.Protocol.Desired
  alias Biot.Protocol.ExecutionSpec
  alias Biot.Protocol.Failure

  @typedoc "The action the controller is running right now, if any."
  @type current_action :: nil | Action.t()

  @typedoc "What one step of the decision returns. `:ready` means the step's resources need nothing."
  @type step :: :ready | {:run, Action.t()} | {:blocked, BlockReason.t()} | {:failed, Failure.t()}

  @type t ::
          :settled
          | {:run, Action.t()}
          | :cancel_current
          | {:blocked, BlockReason.t()}
          | {:failed, Failure.t()}

  @spec next(ExecutionSpec.t(), NodeState.t(), current_action()) :: t()
  def next(%ExecutionSpec{} = spec, %NodeState{} = state, current) do
    with :ready <- current_action(spec, current),
         :ready <- recorded_failure(state, spec.desired.revision) do
      converge(spec, state)
    end
  end

  # Invariant: release never runs while an action is in flight, because every other answer here
  # wins over `converge/2`. The resources an in-flight action needs are therefore retained by
  # construction, and no action has to declare which environments it holds.
  defp current_action(%ExecutionSpec{}, nil), do: :ready

  defp current_action(%ExecutionSpec{desired: %Desired{state: desired}}, action)
       when desired in [:stopped, :destroyed] do
    if Action.cancellable?(action),
      do: :cancel_current,
      else: {:blocked, {:current_action, action}}
  end

  defp current_action(%ExecutionSpec{}, action), do: {:blocked, {:current_action, action}}

  # The controller owns backoff, so a recorded automatic failure means its delay has elapsed.
  defp recorded_failure(%NodeState{failure: {revision, %Failure{retry: :automatic}}}, revision) do
    :ready
  end

  # A build that failed with an old container running stays reported and does nothing else: the old
  # container and its data remain untouched until the desired revision changes.
  defp recorded_failure(%NodeState{failure: {revision, failure}}, revision) do
    {:blocked, {:recorded_failure, failure}}
  end

  # A failure recorded for an older revision says nothing about this one.
  defp recorded_failure(%NodeState{}, _revision), do: :ready

  defp converge(%ExecutionSpec{desired: %Desired{state: :destroyed}} = spec, state) do
    with :ready <- Execution.next(spec, state),
         :ready <- Environment.release(spec, state),
         :ready <- Data.next(spec, state) do
      :settled
    end
  end

  defp converge(%ExecutionSpec{desired: %Desired{state: desired}} = spec, state)
       when desired in [:running, :stopped] do
    with :ready <- Data.next(spec, state),
         :ready <- Environment.next(spec, state),
         :ready <- Execution.next(spec, state),
         :ready <- Environment.release(spec, state) do
      :settled
    end
  end
end
