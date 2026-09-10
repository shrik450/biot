defmodule Biot.Node.Allocation do
  @moduledoc """
  The node's record of the exclusive host resources one biot owns: its UID/GID range, its private
  data root, and its network. These resources are irreplaceable, so the record outlives every
  environment and container.
  """

  alias Biot.Node.NetworkId
  alias Biot.Node.NodePrivatePath
  alias Biot.Protocol.BiotId

  @enforce_keys [:biot_id, :uid_range, :data_root, :network_id, :initialization]
  defstruct [:biot_id, :uid_range, :data_root, :network_id, :initialization]

  @type uid_range :: %{start: non_neg_integer(), count: pos_integer()}

  @typedoc "Working data initialize once, so completion is one fact and needs no identity of its own."
  @type initialization :: :uninitialized | :complete
  @type t :: %__MODULE__{
          biot_id: BiotId.t(),
          uid_range: uid_range(),
          data_root: NodePrivatePath.t(),
          network_id: NetworkId.t(),
          initialization: initialization()
        }

  @spec resources(t()) :: {BiotId.t(), uid_range(), NodePrivatePath.t(), NetworkId.t()}
  def resources(%__MODULE__{} = allocation) do
    {allocation.biot_id, allocation.uid_range, allocation.data_root, allocation.network_id}
  end

  @spec subordinate_start(t(), non_neg_integer()) :: pos_integer()
  def subordinate_start(%__MODULE__{} = allocation, uid_range_base) do
    # Podman's rootless namespace reserves container ID zero for the invoking user.
    allocation.uid_range.start - uid_range_base + 1
  end
end
