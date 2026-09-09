defmodule Biot.Node.Reconcile.Execution do
  @moduledoc """
  Decides the next container action for one biot: retire the container that must go, and start one
  from the installed environment when the biot should run. A container another biot owns is an
  ownership failure, never something this biot may remove.
  """

  alias Biot.Node.Installation
  alias Biot.Node.NodeState
  alias Biot.Node.Reconcile
  alias Biot.Node.Retry
  alias Biot.Protocol.Desired
  alias Biot.Protocol.ExecutionSpec

  @spec next(ExecutionSpec.t(), NodeState.t()) :: Reconcile.step()
  def next(
        %ExecutionSpec{desired: %Desired{state: :running}} = spec,
        %NodeState{} = state
      ) do
    run(spec, state)
  end

  # A stop completes only once the container is inspected absent, which is what lets a later start
  # create a new incarnation. Destruction retires the container the same way.
  def next(
        %ExecutionSpec{desired: %Desired{state: desired}} = spec,
        %NodeState{} = state
      )
      when desired in [:stopped, :destroyed] do
    retire(state.container, spec)
  end

  defp retire({:unknown, failure}, %ExecutionSpec{}), do: {:blocked, {:inspection, failure}}

  defp retire(
         {:present, %{biot_id: biot_id, incarnation_id: incarnation_id}},
         %ExecutionSpec{biot_id: biot_id}
       ),
       do: {:run, {:retire, incarnation_id}}

  defp retire({:present, _container}, %ExecutionSpec{}), do: ownership_mismatch()

  defp retire(:absent, %ExecutionSpec{}), do: :ready

  defp run(%ExecutionSpec{}, %NodeState{container: {:unknown, failure}}) do
    {:blocked, {:inspection, failure}}
  end

  defp run(%ExecutionSpec{} = spec, %NodeState{container: {:present, container}} = state) do
    present(container, spec, state)
  end

  defp run(%ExecutionSpec{} = spec, %NodeState{container: :absent} = state) do
    absent(spec, state)
  end

  # The settled state: a live container running the desired environment from the installation the
  # allocation currently holds.
  defp present(
         %{biot_id: biot_id, state: :running, environment_id: environment_id},
         %ExecutionSpec{biot_id: biot_id, desired: %Desired{environment_id: environment_id}},
         %NodeState{installation: {:present, %Installation{environment_id: environment_id}}}
       ),
       do: :ready

  # Any other container this biot owns has to go: it exited, it runs another environment, or the
  # installation behind it is gone. `Reconcile.Environment` installs once absence is observed.
  defp present(
         %{biot_id: biot_id, incarnation_id: incarnation_id},
         %ExecutionSpec{biot_id: biot_id},
         %NodeState{}
       ),
       do: {:run, {:retire, incarnation_id}}

  defp present(_container, %ExecutionSpec{}, %NodeState{}), do: ownership_mismatch()

  # An exit is reported only after the container is gone, so the automatic retry the controller
  # records always describes an incarnation that no longer holds the biot's data.
  defp absent(%ExecutionSpec{}, %NodeState{pending_exit: %{exit_status: status}}) do
    {:failed, Retry.failure({:container_exited, status}, :start)}
  end

  defp absent(%ExecutionSpec{} = spec, %NodeState{pending_exit: nil} = state) do
    start(spec, state)
  end

  defp start(
         %ExecutionSpec{desired: %Desired{environment_id: environment_id}},
         %NodeState{
           installation: {:present, %Installation{environment_id: environment_id} = installation},
           data: {:present, allocation, _marker}
         }
       ),
       do: {:run, {:start, allocation, installation}}

  # Never create a container against an installation nobody could inspect.
  defp start(%ExecutionSpec{}, %NodeState{installation: {:unknown, _installation, failure}}) do
    {:blocked, {:inspection, failure}}
  end

  # Starting needs the allocation and an installation of the desired environment. `Reconcile.Data`
  # and `Reconcile.Environment` run first, so these states have already produced an earlier action.
  defp start(%ExecutionSpec{}, %NodeState{installation: {:present, %Installation{}}}), do: :ready
  defp start(%ExecutionSpec{}, %NodeState{installation: {:lost, %Installation{}}}), do: :ready
  defp start(%ExecutionSpec{}, %NodeState{installation: nil}), do: :ready

  # Retiring names an incarnation, and this one belongs to another biot: only a person can decide
  # what happens to it.
  defp ownership_mismatch, do: {:failed, Retry.failure(:ownership_mismatch, :retire)}
end
