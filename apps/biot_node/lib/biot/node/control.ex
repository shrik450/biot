defmodule Biot.Node.Control do
  @moduledoc """
  Sends node reports through the current control connection.

  A report never waits for the link. It goes into `Biot.Node.Control.Outbox`, which keeps only the
  latest report of its kind and which the connection drains when it is ready. A node without a
  link, or without a configured connection at all, drops the report: the next synchronization pokes
  every controller, and each one reports what it inspected then.
  """

  alias Biot.Node.Control.Outbox
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.ExecutionReport
  alias Biot.Protocol.Manifest
  alias Biot.Protocol.OrphanedAllocation

  @spec report_observation(BiotId.t(), ExecutionReport.t()) :: :ok
  def report_observation(%BiotId{} = biot_id, %ExecutionReport{} = report) do
    Outbox.put({:observation, biot_id, report})
  end

  @spec report_resolution(EnvironmentId.t(), Manifest.t()) :: :ok
  def report_resolution(%EnvironmentId{} = environment_id, %Manifest{} = manifest) do
    Outbox.put({:resolution, environment_id, manifest})
  end

  @spec report_node_observation([OrphanedAllocation.t()]) :: :ok
  def report_node_observation(orphaned_allocations) when is_list(orphaned_allocations) do
    Outbox.put({:node_observation, orphaned_allocations})
  end
end
