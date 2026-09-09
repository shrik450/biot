defmodule Biot.Node.Orphans do
  @moduledoc """
  The allocations this node holds for biots the server no longer sends intent for.

  Synchronization delivers the complete intent set, so an allocation whose biot has no local
  intent is one the server does not know about. The node reports it and changes nothing: it never
  adopts or deletes a resource on its own.
  """

  alias Biot.Node.Allocation
  alias Biot.Node.LocalIntent
  alias Biot.Protocol.OrphanedAllocation

  @spec detect([Allocation.t()], [LocalIntent.t()]) :: [OrphanedAllocation.t()]
  def detect(allocations, intents) do
    claimed = MapSet.new(intents, & &1.biot_id)

    for %Allocation{biot_id: biot_id, uid_range: uid_range} <- allocations,
        not MapSet.member?(claimed, biot_id),
        do: %OrphanedAllocation{biot_id: biot_id, uid_range: uid_range}
  end
end
