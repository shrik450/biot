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

  @typedoc "Where a caller uses a proof to open a stream."
  @type surface :: :shell | {:preview_host, Hostname.t()}

  @doc """
  Says whether the proof may be used on the surface.

  A preview session acts only on its own preview host (model section 5). The other proofs are
  not scoped to a host.
  """
  @spec accepted_on?(t(), surface()) :: boolean()
  def accepted_on?({:preview, _digest, _parent_digest, hostname, _expires_at}, surface),
    do: surface == {:preview_host, hostname}

  def accepted_on?({:control, _digest, _expires_at}, _surface), do: true
  def accepted_on?({:credential, _credential_id, _expires_at}, _surface), do: true
  def accepted_on?({:ssh_key, _ssh_key_id}, _surface), do: true
end
