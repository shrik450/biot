defmodule Biot.Server.Login.Pending do
  @moduledoc "The short-lived state for one OIDC authorization request."

  alias Biot.Protocol.SameOriginPath

  @enforce_keys [:state, :nonce, :pkce_verifier, :return_path]
  defstruct [:state, :nonce, :pkce_verifier, :return_path]

  @type t :: %__MODULE__{
          state: String.t(),
          nonce: String.t(),
          pkce_verifier: String.t(),
          return_path: SameOriginPath.t()
        }
end
