defmodule Biot.Server.Actor do
  @moduledoc "The authenticated principal that calls a server application function."

  alias Biot.Protocol.PrincipalId

  @enforce_keys [:principal_id]
  defstruct [:principal_id]

  @type t :: %__MODULE__{principal_id: PrincipalId.t()}
end
