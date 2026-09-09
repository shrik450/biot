defmodule Biot.Server.Policy.Unchanged do
  @moduledoc "A policy request that matches the current records."

  alias Biot.Protocol.BiotId
  alias Biot.Server.Policy

  @enforce_keys [:biot_id, :access_revision, :enforcement]
  defstruct [:biot_id, :access_revision, :enforcement]

  @type t :: %__MODULE__{
          biot_id: BiotId.t(),
          access_revision: pos_integer(),
          enforcement: Policy.enforcement()
        }
end
