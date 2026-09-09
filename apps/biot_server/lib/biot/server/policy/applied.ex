defmodule Biot.Server.Policy.Applied do
  @moduledoc "A committed policy change."

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
