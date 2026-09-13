defmodule Biot.Server.Access.Withdrawal do
  @moduledoc """
  Closes local session owners after a committed change, then wakes the nodes that must apply it.

  Callers run this only after their transaction commits. An owner that registers after the close
  then reads the committed policy, and an owner that registered earlier receives the close.
  Owners close before nodes wake because a node applies the new access revision later, and a
  local stream must not stay open for that time.
  """

  alias Biot.Protocol.{BiotId, NodeId}
  alias Biot.Server.Access.Owners
  alias Biot.Server.NodeWake

  @spec enforce([Owners.closure_key()], [{NodeId.t(), BiotId.t()}]) :: :ok
  def enforce(owner_keys, wakes) do
    Enum.each(owner_keys, &Owners.close/1)
    Enum.each(wakes, fn {node_id, biot_id} -> NodeWake.spec_changed(node_id, biot_id) end)
  end
end
