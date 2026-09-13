defmodule Biot.Server.Credentials.Created do
  @moduledoc "A new credential and the clear token shown to its owner once."

  alias Biot.Server.Queries.CredentialView

  @enforce_keys [:credential, :token]
  defstruct [:credential, :token]

  @type t :: %__MODULE__{credential: CredentialView.t(), token: String.t()}
end
