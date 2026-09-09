defmodule Biot.Node.InspectionFailure do
  @moduledoc """
  Why one resource's inspection could not decide whether that resource exists. It keeps `unknown`
  distinct from `absent`, so reconciliation never infers absence from a failed look.
  """

  @type resource :: :allocation | :data | :resolution | :installation | :container | :prepared
  @type reason :: :unavailable | :denied | :timed_out | :unreadable

  @enforce_keys [:resource, :reason, :detail]
  defstruct [:resource, :reason, :detail]

  @type t :: %__MODULE__{resource: resource(), reason: reason(), detail: String.t()}
end
