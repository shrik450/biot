defmodule Biot.Server.Authentication do
  @moduledoc "An authenticated principal with the proof that permits its use."

  alias Biot.Server.Actor
  alias Biot.Server.AuthenticationProof

  @enforce_keys [:actor, :proof]
  defstruct [:actor, :proof]

  @type t :: %__MODULE__{actor: Actor.t(), proof: AuthenticationProof.t()}
end
