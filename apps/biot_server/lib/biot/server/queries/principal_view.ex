defmodule Biot.Server.Queries.PrincipalView do
  @moduledoc """
  The authenticated principal, as it sees itself.

  `email` and `name` are the values the provider sent at the latest login. Either can be nil.
  """

  alias Biot.Protocol.PrincipalId
  alias Biot.Server.Schema.Principal

  @enforce_keys [:id, :email, :name]
  defstruct [:id, :email, :name]

  @type t :: %__MODULE__{
          id: PrincipalId.t(),
          email: String.t() | nil,
          name: String.t() | nil
        }

  @spec project(Principal.t()) :: t()
  def project(%Principal{} = principal) do
    %__MODULE__{
      id: principal.id,
      email: principal.last_seen_email,
      name: principal.last_seen_name
    }
  end
end
