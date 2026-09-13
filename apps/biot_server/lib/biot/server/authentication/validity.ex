defmodule Biot.Server.Authentication.Validity do
  @moduledoc "Owns the shared live-proof queries used by admission and validity checks."

  import Ecto.Query

  alias Biot.Protocol.{CredentialId, Digest, Hostname, SshKeyId}
  alias Biot.Server.Actor
  alias Biot.Server.Authentication
  alias Biot.Server.Schema.{Credential, Principal, Session, SshKey}

  @type proof_key ::
          {:control_session, Digest.t()}
          | {:preview_session, Digest.t()}
          | {:credential, CredentialId.t()}
          | {:ssh_key, SshKeyId.t()}

  @spec proof_key?(term()) :: boolean()
  def proof_key?({:control_session, %Digest{}}), do: true
  def proof_key?({:preview_session, %Digest{}}), do: true
  def proof_key?({:credential, %CredentialId{}}), do: true
  def proof_key?({:ssh_key, %SshKeyId{}}), do: true
  def proof_key?(_key), do: false

  @spec proof_keys(Authentication.t()) :: [proof_key(), ...]
  def proof_keys(%Authentication{proof: {:control, %Digest{} = digest, _expires_at}}),
    do: [{:control_session, digest}]

  def proof_keys(%Authentication{
        proof: {:preview, %Digest{} = digest, %Digest{} = parent_digest, _hostname, _expires_at}
      }),
      do: [{:preview_session, digest}, {:control_session, parent_digest}]

  def proof_keys(%Authentication{
        proof: {:credential, %CredentialId{} = credential_id, _expires_at}
      }),
      do: [{:credential, credential_id}]

  def proof_keys(%Authentication{proof: {:ssh_key, %SshKeyId{} = key_id}}),
    do: [{:ssh_key, key_id}]

  @doc "Returns the proof's live expiry, or nil for a proof that never expires."
  @spec check(Ecto.Repo.t() | module(), Authentication.t(), DateTime.t()) ::
          {:ok, DateTime.t() | nil} | {:error, :unauthenticated}
  def check(
        repo,
        %Authentication{actor: %Actor{principal_id: principal_id}, proof: proof},
        %DateTime{} = now
      ),
      do: check_proof(repo, principal_id, proof, now)

  @spec key_valid?(Ecto.Repo.t() | module(), proof_key(), DateTime.t()) :: boolean()
  def key_valid?(repo, {:control_session, digest}, now) do
    not is_nil(control_session(repo, digest, now))
  end

  def key_valid?(repo, {:preview_session, digest}, now) do
    not is_nil(preview_session_with_parent(repo, digest, nil, now))
  end

  def key_valid?(repo, {:credential, credential_id}, now) do
    not is_nil(credential(repo, credential_id, now))
  end

  def key_valid?(repo, {:ssh_key, key_id}, _now) do
    not is_nil(ssh_key(repo, key_id))
  end

  @spec control_session(Ecto.Repo.t() | module(), Digest.t(), DateTime.t()) :: Session.t() | nil
  def control_session(repo, %Digest{} = digest, %DateTime{} = now) do
    from(session in Session,
      join: principal in Principal,
      on: principal.id == session.principal_id,
      where:
        session.id_digest == ^digest and session.scope == :control and
          session.expires_at > ^now and principal.status == :enabled,
      select: session
    )
    |> repo.one()
  end

  @spec preview_session(Ecto.Repo.t() | module(), Digest.t(), Hostname.t(), DateTime.t()) ::
          Session.t() | nil
  def preview_session(repo, %Digest{} = digest, %Hostname{} = hostname, %DateTime{} = now) do
    case preview_session_with_parent(repo, digest, hostname, now) do
      {session, _parent} -> session
      nil -> nil
    end
  end

  # A nil hostname matches a preview row for any host.
  defp preview_session_with_parent(
         repo,
         %Digest{} = digest,
         hostname,
         %DateTime{} = now
       ) do
    from(session in Session,
      join: parent in Session,
      on: parent.id_digest == session.control_session_digest,
      join: principal in Principal,
      on: principal.id == session.principal_id and principal.id == parent.principal_id,
      where:
        session.id_digest == ^digest and session.scope == :preview and
          session.expires_at > ^now and
          parent.scope == :control and parent.expires_at > ^now and
          principal.status == :enabled,
      select: {session, parent}
    )
    |> maybe_hostname(hostname)
    |> repo.one()
  end

  defp maybe_hostname(query, nil), do: query

  defp maybe_hostname(query, %Hostname{} = hostname),
    do: where(query, [session, _parent, _principal], session.hostname == ^hostname)

  @spec credential(Ecto.Repo.t() | module(), CredentialId.t(), DateTime.t()) ::
          Credential.t() | nil
  defp credential(repo, %CredentialId{} = credential_id, %DateTime{} = now) do
    from(credential in Credential,
      join: principal in Principal,
      on: principal.id == credential.principal_id,
      where:
        credential.id == ^credential_id and credential.expires_at > ^now and
          principal.status == :enabled,
      select: credential
    )
    |> repo.one()
  end

  @spec credential_by_digest(Ecto.Repo.t() | module(), Digest.t(), DateTime.t()) ::
          Credential.t() | nil
  def credential_by_digest(repo, %Digest{} = digest, %DateTime{} = now) do
    from(credential in Credential,
      join: principal in Principal,
      on: principal.id == credential.principal_id,
      where:
        credential.secret_digest == ^digest and credential.expires_at > ^now and
          principal.status == :enabled,
      select: credential
    )
    |> repo.one()
  end

  @spec ssh_key(Ecto.Repo.t() | module(), SshKeyId.t()) :: SshKey.t() | nil
  defp ssh_key(repo, %SshKeyId{} = key_id) do
    from(key in SshKey,
      join: principal in Principal,
      on: principal.id == key.principal_id,
      where: key.id == ^key_id and principal.status == :enabled,
      select: key
    )
    |> repo.one()
  end

  @spec ssh_key_by_fingerprint(Ecto.Repo.t() | module(), String.t()) :: SshKey.t() | nil
  def ssh_key_by_fingerprint(repo, fingerprint) when is_binary(fingerprint) do
    from(key in SshKey,
      join: principal in Principal,
      on: principal.id == key.principal_id,
      where: key.fingerprint == ^fingerprint and principal.status == :enabled,
      select: key
    )
    |> repo.one()
  end

  defp check_proof(repo, principal_id, {:control, %Digest{} = digest, _proof_expiry}, now) do
    case control_session(repo, digest, now) do
      %Session{principal_id: ^principal_id, expires_at: expires_at} ->
        {:ok, expires_at}

      _missing_or_mismatched ->
        {:error, :unauthenticated}
    end
  end

  defp check_proof(
         repo,
         principal_id,
         {:preview, %Digest{} = digest, %Digest{} = parent_digest, %Hostname{} = hostname,
          _proof_expiry},
         now
       ) do
    case preview_session_with_parent(repo, digest, hostname, now) do
      {
        %Session{
          principal_id: ^principal_id,
          control_session_digest: ^parent_digest,
          expires_at: expires_at
        },
        %Session{expires_at: parent_expires_at}
      } ->
        {:ok, earlier_expiry(expires_at, parent_expires_at)}

      _missing_or_mismatched ->
        {:error, :unauthenticated}
    end
  end

  defp check_proof(
         repo,
         principal_id,
         {:credential, %CredentialId{} = credential_id, _proof_expiry},
         now
       ) do
    case credential(repo, credential_id, now) do
      %Credential{principal_id: ^principal_id, expires_at: expires_at} ->
        {:ok, expires_at}

      _missing_or_mismatched ->
        {:error, :unauthenticated}
    end
  end

  defp check_proof(repo, principal_id, {:ssh_key, %SshKeyId{} = key_id}, _now) do
    case ssh_key(repo, key_id) do
      %SshKey{principal_id: ^principal_id} ->
        {:ok, nil}

      _missing_or_mismatched ->
        {:error, :unauthenticated}
    end
  end

  defp earlier_expiry(first, second) do
    if DateTime.compare(first, second) == :gt, do: second, else: first
  end
end
