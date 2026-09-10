defmodule Biot.Node.Reconcile.Data do
  @moduledoc """
  Decides the next allocation or working-data action for one biot. Working data belong to the
  stable allocation, so this step establishes them before anything replaceable is built, and gives
  them back last when the biot is destroyed.
  """

  alias Biot.Node.NodeState
  alias Biot.Node.Reconcile
  alias Biot.Node.Retry
  alias Biot.Protocol.Desired
  alias Biot.Protocol.ExecutionSpec

  @spec next(ExecutionSpec.t(), NodeState.t()) :: Reconcile.step()
  def next(%ExecutionSpec{desired: %Desired{state: :destroyed}}, %NodeState{} = state) do
    removal(state.data)
  end

  def next(%ExecutionSpec{} = spec, %NodeState{} = state) do
    establish(state.data, spec)
  end

  defp establish(:no_allocation, %ExecutionSpec{biot_id: biot_id}) do
    {:run, {:allocate, biot_id}}
  end

  defp establish({:unknown, _allocation, failure}, %ExecutionSpec{}) do
    {:blocked, {:inspection, failure}}
  end

  defp establish({:uninitialized, allocation}, %ExecutionSpec{repository: repository}) do
    {:run, {:initialize, allocation, repository}}
  end

  defp establish({:present, _allocation}, %ExecutionSpec{}), do: :ready

  # Initialized data are never silently replaced. A completed initialization whose data are gone is
  # a visible loss for the operator, not permission to clone again over the biot's identity.
  defp establish({:lost, _allocation}, %ExecutionSpec{}) do
    {:failed, Retry.failure(:lost_data, :initialize)}
  end

  defp removal({:unknown, _allocation, failure}), do: {:blocked, {:inspection, failure}}
  defp removal({:present, allocation}), do: {:run, {:remove_data, allocation}}

  # `remove_data` converges, so it also clears a completion marker whose data are already gone.
  defp removal({:lost, allocation}), do: {:run, {:remove_data, allocation}}

  # The UID range and the data root are only reusable once both the container and the data are
  # inspected absent, which is why releasing the allocation comes last.
  defp removal({:uninitialized, allocation}), do: {:run, {:release_allocation, allocation}}
  defp removal(:no_allocation), do: :ready
end
