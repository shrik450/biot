defmodule Biot.Node.Observation do
  @moduledoc """
  The two pure projections a controller makes from one host inspection: the `NodeState`
  reconciliation reads, and the `ExecutionReport` the server stores.

  Both live here because they read the same facts. `node_state/4` adds the two facts inspection
  cannot see, the container exit the controller still owes a failure for and the failure it
  recorded, and `report/2` states what the node inspected without deciding anything.
  """

  alias Biot.Node.Host.Inspection
  alias Biot.Node.Installation
  alias Biot.Node.NodeState
  alias Biot.Protocol.BiotSpec
  alias Biot.Protocol.Desired
  alias Biot.Protocol.ExecutionReport

  @spec node_state(
          Inspection.t(),
          Desired.t(),
          NodeState.pending_exit(),
          NodeState.recorded_failure()
        ) :: NodeState.t()
  def node_state(%Inspection{} = inspection, %Desired{} = desired, pending_exit, failure) do
    %NodeState{
      data: inspection.data,
      resolutions: inspection.resolutions,
      installation: inspection.installation,
      container: inspection.container,
      prepared: inspection.prepared,
      pending_exit: pending_exit(desired, inspection.container, pending_exit),
      failure: failure
    }
  end

  @spec report(BiotSpec.t(), NodeState.t()) :: ExecutionReport.t()
  def report(%BiotSpec{} = spec, %NodeState{} = state) do
    %ExecutionReport{
      accepted_revision: spec.execution.desired.revision,
      installed_environment_id: installed_environment_id(state.installation),
      container: container(state.container),
      data: data(state.data),
      failure: state.failure
    }
  end

  # A biot that no longer wants to run has no exit left to explain.
  defp pending_exit(%Desired{state: desired}, _container, _carried) when desired != :running do
    nil
  end

  # The first inspection that sees the exit takes it, and it stays until the controller records the
  # failure for it. That is what lets reconciliation retire the exited container first.
  defp pending_exit(
         %Desired{},
         {:present, %{state: {:exited, status}, incarnation_id: incarnation_id}},
         _carried
       ) do
    %{incarnation_id: incarnation_id, exit_status: status}
  end

  defp pending_exit(%Desired{}, _container, carried), do: carried

  # Only an installation whose artifact was inspected present is installed. An unreadable or lost
  # artifact is not something the server should read as a running environment.
  defp installed_environment_id({:present, %Installation{environment_id: environment_id}}) do
    environment_id
  end

  defp installed_environment_id(_installation), do: nil

  defp container({:present, %{incarnation_id: incarnation_id, state: container_state}}) do
    {:present, incarnation_id, container_state}
  end

  defp container(:absent), do: :absent
  defp container({:unknown, _failure}), do: :unknown

  defp data(:no_allocation), do: :no_allocation
  defp data({:unknown, _allocation, _failure}), do: :unknown
  defp data({:uninitialized, _allocation}), do: :uninitialized
  defp data({:present, _allocation}), do: :present
  defp data({:lost, _allocation}), do: :lost
end
