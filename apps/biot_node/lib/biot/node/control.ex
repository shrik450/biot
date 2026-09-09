defmodule Biot.Node.Control do
  @moduledoc "Sends node reports through the current control connection."

  alias Biot.Node.Control.Connection
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.ExecutionReport
  alias Biot.Protocol.Manifest
  alias Biot.Protocol.OrphanedAllocation

  @spec report_observation(BiotId.t(), ExecutionReport.t()) :: :ok | {:error, :disconnected}
  def report_observation(%BiotId{} = biot_id, %ExecutionReport{} = report) do
    Connection.send_report({:observation, biot_id, report})
  end

  @spec report_resolution(EnvironmentId.t(), Manifest.t()) :: :ok | {:error, :disconnected}
  def report_resolution(%EnvironmentId{} = environment_id, %Manifest{} = manifest) do
    Connection.send_report({:resolution, environment_id, manifest})
  end

  @spec report_node_observation([OrphanedAllocation.t()]) :: :ok | {:error, :disconnected}
  def report_node_observation(orphaned_allocations) when is_list(orphaned_allocations) do
    Connection.send_report({:node_observation, orphaned_allocations})
  end
end
