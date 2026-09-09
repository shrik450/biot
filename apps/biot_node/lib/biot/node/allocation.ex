defmodule Biot.Node.Allocation do
  @moduledoc """
  The node's record of the exclusive host resources one biot owns: its UID/GID range, its private
  data root, and its network. These resources are irreplaceable, so the record outlives every
  environment and container.
  """

  alias Biot.Node.MarkerId
  alias Biot.Node.NetworkId
  alias Biot.Node.NodePrivatePath
  alias Biot.Protocol.BiotId

  @enforce_keys [:biot_id, :uid_range, :data_root, :network_id, :initialization]
  defstruct [:biot_id, :uid_range, :data_root, :network_id, :initialization]

  @type uid_range :: %{start: non_neg_integer(), count: pos_integer()}
  @type initialization :: :uninitialized | {:complete, MarkerId.t()}
  @type t :: %__MODULE__{
          biot_id: BiotId.t(),
          uid_range: uid_range(),
          data_root: NodePrivatePath.t(),
          network_id: NetworkId.t(),
          initialization: initialization()
        }
end
