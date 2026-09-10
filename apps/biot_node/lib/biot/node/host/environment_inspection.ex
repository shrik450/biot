defmodule Biot.Node.Host.EnvironmentInspection do
  @moduledoc "Derives environment states from journal rows and inspected host facts."

  alias Biot.Node.ArtifactId
  alias Biot.Node.Diagnostic
  alias Biot.Node.Host.FileSystem
  alias Biot.Node.Host.Outcome
  alias Biot.Node.Installation
  alias Biot.Node.NodeState
  alias Biot.Node.Resolution
  alias Biot.Protocol.EnvironmentId

  @type resolution_fact :: :not_needed | FileSystem.fact(:directory)
  @type artifact_fact :: :absent | {:present, ArtifactId.t()} | {:error, {term(), String.t()}}

  @spec resolutions([{Resolution.t(), resolution_fact()}]) :: %{
          EnvironmentId.t() => NodeState.resolution_state()
        }
  def resolutions(rows_and_facts) do
    Map.new(rows_and_facts, fn {resolution, fact} ->
      {resolution.environment_id, resolution_state(resolution, fact)}
    end)
  end

  @doc """
  One resource per environment. Each root is inspected on its own, so a root the node could not
  read leaves only its own environment `unknown`.
  """
  @spec prepared([{EnvironmentId.t(), artifact_fact()}]) :: NodeState.prepared()
  def prepared(facts) do
    Map.new(facts, fn {environment_id, fact} -> {environment_id, artifact_state(fact)} end)
  end

  @spec installation(Installation.t() | nil, NodeState.prepared()) ::
          NodeState.installation_state()
  def installation(nil, _prepared), do: nil

  def installation(%Installation{} = installation, prepared) do
    installed_state(installation, Map.get(prepared, installation.environment_id, :absent))
  end

  defp artifact_state(:absent), do: :absent
  defp artifact_state({:present, artifact_id}), do: {:present, artifact_id}

  defp artifact_state({:error, {reason, detail}}) do
    {:unknown, Outcome.inspection(:prepared, reason, Diagnostic.text(detail))}
  end

  defp installed_state(
         %Installation{artifact_id: artifact_id} = installation,
         {:present, artifact_id}
       ),
       do: {:present, installation}

  # An artifact that is gone, or one the environment replaced, leaves nothing this installation
  # names. Only the environment's own root can answer for it.
  defp installed_state(%Installation{} = installation, {:present, _other_artifact_id}) do
    {:lost, installation}
  end

  defp installed_state(%Installation{} = installation, :absent), do: {:lost, installation}

  defp installed_state(%Installation{} = installation, {:unknown, failure}) do
    {:unknown, installation, failure}
  end

  defp resolution_state(%Resolution{} = resolution, :not_needed), do: {:present, resolution}

  defp resolution_state(%Resolution{} = resolution, {:present, :directory}),
    do: {:present, resolution}

  defp resolution_state(%Resolution{} = resolution, :absent), do: {:lost, resolution}

  defp resolution_state(%Resolution{} = resolution, {:error, reason}) do
    failure =
      Outcome.inspection(
        :resolution,
        reason,
        Diagnostic.text("the project snapshot could not be inspected")
      )

    {:unknown, resolution, failure}
  end
end
