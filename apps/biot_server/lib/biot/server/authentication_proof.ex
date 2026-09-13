defmodule Biot.Server.AuthenticationProof do
  @moduledoc """
  The proof a caller presented, named by the surface that read it.

  A proof carries only stored identifiers and digests. It never carries a clear
  token. Browser proofs name the session the token was found in; only a control
  proof lets the caller end the browser login.
  """

  alias Biot.Protocol.{CredentialId, Digest, Hostname, SshKeyId}

  @type t ::
          {:control, Digest.t(), DateTime.t()}
          | {:preview, Digest.t(), Digest.t(), Hostname.t(), DateTime.t()}
          | {:credential, CredentialId.t(), DateTime.t()}
          | {:ssh_key, SshKeyId.t()}

  @spec control(Digest.t(), DateTime.t()) :: t()
  def control(%Digest{} = session_digest, %DateTime{} = expires_at),
    do: {:control, session_digest, expires_at}

  @spec preview(Digest.t(), Digest.t(), Hostname.t(), DateTime.t()) :: t()
  def preview(
        %Digest{} = session_digest,
        %Digest{} = control_session_digest,
        %Hostname{} = hostname,
        %DateTime{} = expires_at
      ),
      do: {:preview, session_digest, control_session_digest, hostname, expires_at}

  @spec credential(CredentialId.t(), DateTime.t()) :: t()
  def credential(%CredentialId{} = credential_id, %DateTime{} = expires_at),
    do: {:credential, credential_id, expires_at}

  @spec ssh_key(SshKeyId.t()) :: t()
  def ssh_key(%SshKeyId{} = ssh_key_id), do: {:ssh_key, ssh_key_id}
end
