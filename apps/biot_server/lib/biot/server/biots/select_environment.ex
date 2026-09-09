defmodule Biot.Server.Biots.SelectEnvironment do
  @moduledoc "The parsed environment selection for a lifecycle update."

  alias Biot.Protocol.EnvironmentSelection

  @enforce_keys [:selection]
  defstruct [:selection]

  @type t :: %__MODULE__{selection: EnvironmentSelection.t()}
end
