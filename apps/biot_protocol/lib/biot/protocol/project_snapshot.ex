defmodule Biot.Protocol.ProjectSnapshot do
  @moduledoc "A project snapshot identified by an ID and its digest."

  alias Biot.Protocol.Digest

  @enforce_keys [:snapshot_id, :digest]
  defstruct [:snapshot_id, :digest]

  @type t :: %__MODULE__{
          snapshot_id: String.t(),
          digest: Digest.t()
        }
end
