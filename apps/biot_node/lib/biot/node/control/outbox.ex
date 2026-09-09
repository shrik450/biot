defmodule Biot.Node.Control.Outbox do
  @moduledoc """
  The bounded set of reports waiting for the control link.

  The node reports what it inspected, not a history of what it inspected, so the outbox keeps one
  latest observation per biot, one resolution per environment, and one node observation. A new
  report replaces the one it supersedes. A blocked or slow link therefore costs one entry per biot
  instead of a growing queue of reports in the connection's mailbox.

  Invariant: at most one wakeup for this table sits in the connection's mailbox. A writer wakes the
  connection only when it is the first to write since the last drain, and the connection deletes
  that marker before it reads, so a report written during a drain always sends the next wakeup
  itself.

  The connection owns the table and drains it whenever the link is ready. A node with no configured
  server has no connection and no table, and a writer then drops the report: the next
  synchronization pokes every controller, which reports what it inspected again.
  """

  alias Biot.Node.Control.Connection
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.ExecutionReport
  alias Biot.Protocol.Manifest
  alias Biot.Protocol.OrphanedAllocation

  @table __MODULE__
  @wakeup :wakeup

  @type report ::
          {:observation, BiotId.t(), ExecutionReport.t()}
          | {:resolution, EnvironmentId.t(), Manifest.t()}
          | {:node_observation, [OrphanedAllocation.t()]}

  @doc "Creates the table. The calling process owns it and is the one `put/1` wakes."
  @spec open() :: :ok
  def open do
    @table = :ets.new(@table, [:named_table, :set, :public, write_concurrency: true])
    :ok
  end

  @doc "Adds one report, replacing the one it supersedes, and wakes the connection if needed."
  @spec put(report()) :: :ok
  def put(report) do
    case :ets.whereis(@table) do
      :undefined -> :ok
      table -> write(table, report)
    end
  end

  @doc "Every report waiting right now, removed from the table."
  @spec drain() :: [report()]
  def drain do
    :ets.delete(@table, @wakeup)

    @table
    |> :ets.select([{{:"$1", :_}, [{:"/=", :"$1", @wakeup}], [:"$1"]}])
    |> Enum.flat_map(fn key ->
      case :ets.take(@table, key) do
        [{^key, report}] -> [report]
        [] -> []
      end
    end)
  end

  defp write(table, report) do
    true = :ets.insert(table, {key(report), report})
    if :ets.insert_new(table, {@wakeup, true}), do: Connection.wake()
    :ok
  end

  defp key({:observation, biot_id, _report}), do: {:observation, biot_id}
  defp key({:resolution, environment_id, _manifest}), do: {:resolution, environment_id}
  defp key({:node_observation, _orphaned_allocations}), do: :node_observation
end
