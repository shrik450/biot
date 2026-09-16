defmodule Biot.Server.CommitEffects do
  @moduledoc """
  Runs the side effects that follow one committed durable change.

  Callers run this only after their transaction commits, so every effect reads committed state.
  Owners close before nodes wake because a node applies the new access revision later, and a local
  stream must not stay open for that time. `readers` names the Biots whose durable state changed;
  every browser reader of one is notified after the change is visible to a new query.
  """

  alias Biot.Protocol.{BiotId, NodeId}
  alias Biot.Server.Access.Owners
  alias Biot.Server.BiotChange
  alias Biot.Server.NodeWake

  @enforce_keys [:owners, :wakes, :readers]
  defstruct [:owners, :wakes, :readers]

  @type t :: %__MODULE__{
          owners: [Owners.closure_key()],
          wakes: [{NodeId.t(), BiotId.t()}],
          readers: [BiotId.t()]
        }

  @spec enforce(t()) :: :ok
  def enforce(%__MODULE__{owners: owners, wakes: wakes, readers: readers}) do
    Enum.each(owners, &Owners.close/1)
    Enum.each(wakes, fn {node_id, biot_id} -> NodeWake.spec_changed(node_id, biot_id) end)
    Enum.each(readers, &BiotChange.changed/1)
  end
end
