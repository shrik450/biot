defmodule Biot.Server.Queries.CredentialView do
  @moduledoc "One bearer credential, as its owner sees it. Never the clear token."

  alias Biot.Protocol.CredentialId
  alias Biot.Server.Schema.Credential

  @enforce_keys [:id, :label, :expires_at, :last_used_at]
  defstruct [:id, :label, :expires_at, :last_used_at]

  @type t :: %__MODULE__{
          id: CredentialId.t(),
          label: String.t(),
          expires_at: DateTime.t(),
          last_used_at: DateTime.t() | nil
        }

  @spec project(Credential.t()) :: t()
  def project(%Credential{} = credential) do
    %__MODULE__{
      id: credential.id,
      label: credential.label,
      expires_at: credential.expires_at,
      last_used_at: credential.last_used_at
    }
  end
end
