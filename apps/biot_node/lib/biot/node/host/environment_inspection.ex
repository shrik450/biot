defmodule Biot.Node.Host.EnvironmentInspection do
  @moduledoc "Derives environment states from journal rows and inspected host facts."

  alias Biot.Node.Host.Outcome
  alias Biot.Node.Installation
  alias Biot.Node.Resolution
  alias Biot.Protocol.EnvironmentId

  @type resolution_fact :: :not_needed | Biot.Node.Host.FileSystem.fact(:directory)
  @type artifact_fact :: :absent | {:present, Biot.Node.ArtifactId.t()} | {:error, term()}

  @spec resolutions([{Resolution.t(), resolution_fact()}]) :: %{
          EnvironmentId.t() => Biot.Node.NodeState.resolution_state()
        }
  def resolutions(rows_and_facts) do
    Map.new(rows_and_facts, fn {resolution, fact} ->
      {resolution.environment_id, resolution_state(resolution, fact)}
    end)
  end

  @spec prepared([{EnvironmentId.t(), artifact_fact()}]) :: Biot.Node.NodeState.resource(map())
  def prepared(facts) do
    Enum.reduce_while(facts, {:present, %{}}, fn
      {_environment_id, :absent}, {:present, artifacts} ->
        {:cont, {:present, artifacts}}

      {environment_id, {:present, artifact_id}}, {:present, artifacts} ->
        {:cont, {:present, Map.put(artifacts, environment_id, artifact_id)}}

      {_environment_id, {:error, {reason, detail}}}, _artifacts ->
        failure = Outcome.inspection(:prepared, reason, detail)
        {:halt, {:unknown, failure}}
    end)
  end

  @spec installation(Installation.t() | nil, Biot.Node.NodeState.resource(map())) ::
          Biot.Node.NodeState.installation_state()
  def installation(nil, _prepared), do: nil

  def installation(%Installation{} = installation, {:present, artifacts}) do
    if Map.get(artifacts, installation.environment_id) == installation.artifact_id,
      do: {:present, installation},
      else: {:lost, installation}
  end

  def installation(%Installation{} = installation, {:unknown, failure}) do
    {:unknown, installation, failure}
  end

  defp resolution_state(%Resolution{} = resolution, :not_needed), do: {:present, resolution}

  defp resolution_state(%Resolution{} = resolution, {:present, :directory}),
    do: {:present, resolution}

  defp resolution_state(%Resolution{} = resolution, :absent), do: {:lost, resolution}

  defp resolution_state(%Resolution{} = resolution, {:error, reason}) do
    failure =
      Outcome.inspection(:resolution, reason, "the project snapshot could not be inspected")

    {:unknown, resolution, failure}
  end
end
