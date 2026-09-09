defmodule Biot.Node.Reconcile.Environment do
  @moduledoc """
  Decides the next environment action for one biot: resolve the desired environment, prepare its
  artifact, install it against the allocation, and give back what the biot no longer needs.

  `release/2` runs only after every other step is ready, so giving a resource back never wins over
  a pending desired-state action.
  """

  alias Biot.Node.Installation
  alias Biot.Node.NodeState
  alias Biot.Node.Reconcile
  alias Biot.Node.Resolution
  alias Biot.Protocol.Desired
  alias Biot.Protocol.ExecutionSpec

  @spec next(ExecutionSpec.t(), NodeState.t()) :: Reconcile.step()
  def next(
        %ExecutionSpec{desired: %Desired{state: :running}} = spec,
        %NodeState{} = state
      ) do
    desired_installation(spec, state)
  end

  # A stopped biot installs nothing new, and a destroyed one wants nothing at all. Preparation
  # already in flight may finish; `release/2` decides what to give back.
  def next(%ExecutionSpec{desired: %Desired{state: :stopped}}, %NodeState{}), do: :ready

  def next(%ExecutionSpec{desired: %Desired{state: :destroyed}}, %NodeState{}),
    do: :ready

  @doc """
  The one environment whose prepared artifact and resolution snapshot the biot no longer needs, if
  any. An environment is retained while it is desired, installed, or used by a live container.
  """
  @spec release(ExecutionSpec.t(), NodeState.t()) :: Reconcile.step()
  # A container inspection that failed leaves the running environment unknown, and releasing an
  # artifact a live container uses would break it.
  def release(%ExecutionSpec{}, %NodeState{container: {:unknown, _failure}}), do: :ready

  def release(%ExecutionSpec{} = spec, %NodeState{} = state) do
    retained = retained(spec, state)

    case Enum.find(candidates(state), &(not MapSet.member?(retained, &1))) do
      nil -> :ready
      environment_id -> {:run, {:release_environment, environment_id}}
    end
  end

  defp desired_installation(
         %ExecutionSpec{} = spec,
         %NodeState{data: {:present, allocation, _marker}} = state
       ) do
    installation_step(state.installation, spec, state, allocation)
  end

  # Preparation writes into the allocation's private location, and `Reconcile.Data` establishes
  # that allocation first, so these states have already produced an earlier action.
  defp desired_installation(%ExecutionSpec{}, %NodeState{data: :no_allocation}), do: :ready

  defp desired_installation(%ExecutionSpec{}, %NodeState{data: {:unknown, _allocation, _failure}}),
       do: :ready

  defp desired_installation(%ExecutionSpec{}, %NodeState{data: {:uninitialized, _allocation}}),
    do: :ready

  defp desired_installation(%ExecutionSpec{}, %NodeState{data: {:lost, _allocation}}), do: :ready

  defp installation_step(
         {:unknown, _installation, failure},
         %ExecutionSpec{},
         %NodeState{},
         _allocation
       ) do
    {:blocked, {:inspection, failure}}
  end

  defp installation_step(
         {:present, %Installation{environment_id: environment_id}},
         %ExecutionSpec{desired: %Desired{environment_id: environment_id}},
         %NodeState{},
         _allocation
       ),
       do: :ready

  defp installation_step({:present, %Installation{}}, spec, state, allocation) do
    install_desired(spec, state, allocation)
  end

  # A missing installed artifact is no reason to choose a different environment: prepare and
  # install the desired one again. `Reconcile.Execution` retires the container that was using it.
  defp installation_step({:lost, %Installation{}}, spec, state, allocation) do
    install_desired(spec, state, allocation)
  end

  defp installation_step(nil, spec, state, allocation) do
    install_desired(spec, state, allocation)
  end

  defp install_desired(%ExecutionSpec{} = spec, %NodeState{} = state, allocation) do
    environment_id = spec.desired.environment_id

    case artifact(state.prepared, environment_id) do
      {:present, artifact_id} -> install_step(state.container, spec, allocation, artifact_id)
      :absent -> resolution_step(Map.fetch(state.resolutions, environment_id), spec, allocation)
      {:unknown, failure} -> {:blocked, {:inspection, failure}}
    end
  end

  defp artifact({:present, artifacts}, environment_id) do
    case Map.fetch(artifacts, environment_id) do
      {:ok, artifact_id} -> {:present, artifact_id}
      :error -> :absent
    end
  end

  defp artifact(:absent, _environment_id), do: :absent
  defp artifact({:unknown, failure}, _environment_id), do: {:unknown, failure}

  # At most one container uses a biot's writable data, so the previous container must be inspected
  # absent before the allocation selects a different artifact.
  defp install_step(:absent, %ExecutionSpec{} = spec, allocation, artifact_id) do
    {:run, {:install, allocation, artifact_id, spec.desired.environment_id}}
  end

  # `Reconcile.Execution` retires the container that still uses the old installation.
  defp install_step({:present, _container}, %ExecutionSpec{}, _allocation, _artifact_id),
    do: :ready

  defp install_step({:unknown, failure}, %ExecutionSpec{}, _allocation, _artifact_id) do
    {:blocked, {:inspection, failure}}
  end

  defp resolution_step(
         {:ok, {:present, %Resolution{manifest: manifest}}},
         %ExecutionSpec{desired: %Desired{environment_id: environment_id}},
         _allocation
       ),
       do: {:run, {:prepare, environment_id, manifest}}

  defp resolution_step({:ok, {:unknown, %Resolution{}, failure}}, %ExecutionSpec{}, _allocation) do
    {:blocked, {:inspection, failure}}
  end

  # A lost snapshot only stops this environment from being prepared; an intact installed artifact
  # keeps running, and resolving again is atomic.
  defp resolution_step({:ok, {:lost, %Resolution{}}}, spec, allocation) do
    resolve(spec, allocation)
  end

  # No entry means the node has never resolved this environment.
  defp resolution_step(:error, spec, allocation), do: resolve(spec, allocation)

  defp resolve(%ExecutionSpec{} = spec, allocation) do
    {:run, {:resolve, spec.desired.environment_id, spec.environment.selection, allocation}}
  end

  # A destroyed biot keeps nothing of its own; only a live container or the running action can
  # still need an artifact.
  defp retained(
         %ExecutionSpec{desired: %Desired{state: :destroyed}},
         %NodeState{} = state
       ) do
    MapSet.new(running_environments(state.container))
  end

  defp retained(%ExecutionSpec{desired: desired}, %NodeState{} = state) do
    MapSet.new(
      [desired.environment_id] ++
        installed_environments(state.installation) ++
        running_environments(state.container)
    )
  end

  defp installed_environments({:present, %Installation{environment_id: environment_id}}),
    do: [environment_id]

  # An installation nobody could inspect may still be in use.
  defp installed_environments({:unknown, %Installation{environment_id: environment_id}, _failure}) do
    [environment_id]
  end

  # A lost installation has no artifact left to retain.
  defp installed_environments({:lost, %Installation{}}), do: []
  defp installed_environments(nil), do: []

  defp running_environments({:present, %{environment_id: environment_id}}), do: [environment_id]
  defp running_environments(:absent), do: []
  defp running_environments({:unknown, _failure}), do: []

  defp candidates(%NodeState{} = state) do
    prepared_environments(state.prepared) ++ snapshot_environments(state.resolutions)
  end

  defp prepared_environments({:present, artifacts}), do: Map.keys(artifacts)
  defp prepared_environments(:absent), do: []

  # An unreadable prepared set contributes no candidates; a recorded resolution can still safely
  # release an unretained environment because no resource is retained for it.
  defp prepared_environments({:unknown, _failure}), do: []

  defp snapshot_environments(resolutions) do
    Enum.flat_map(resolutions, fn {environment_id, resolution} ->
      snapshot_environment(environment_id, resolution)
    end)
  end

  defp snapshot_environment(environment_id, {:present, %Resolution{}}), do: [environment_id]
  defp snapshot_environment(environment_id, {:lost, %Resolution{}}), do: [environment_id]
  defp snapshot_environment(_environment_id, {:unknown, %Resolution{}, _failure}), do: []
end
