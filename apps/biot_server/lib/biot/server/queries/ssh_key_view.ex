defmodule Biot.Server.Queries.SshKeyView do
  @moduledoc "One registered SSH public key, as its owner sees it."

  alias Biot.Protocol.{SshKeyId, SshPublicKey}
  alias Biot.Server.Schema.SshKey

  @enforce_keys [:id, :public_key, :fingerprint, :label]
  defstruct [:id, :public_key, :fingerprint, :label]

  @type t :: %__MODULE__{
          id: SshKeyId.t(),
          public_key: SshPublicKey.t(),
          fingerprint: String.t(),
          label: String.t()
        }

  @spec project(SshKey.t()) :: t()
  def project(%SshKey{} = key) do
    %__MODULE__{
      id: key.id,
      public_key: key.public_key,
      fingerprint: key.fingerprint,
      label: key.label
    }
  end
end
