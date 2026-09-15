defmodule Biot.Server.Credentials do
  @moduledoc """
  Owns bearer credentials.

  A credential is minted only from a live control proof, so a credential or a
  preview cannot issue another. The server stores only the token digest; the
  clear token is returned once.
  """

  import Ecto.Query

  alias Biot.Protocol.CredentialId
  alias Biot.Server.Access.Owners
  alias Biot.Server.Actor
  alias Biot.Server.Authentication
  alias Biot.Server.Authentication.Validity
  alias Biot.Server.AuthenticationProof
  alias Biot.Server.CommandError
  alias Biot.Server.Credentials.Created
  alias Biot.Server.Label
  alias Biot.Server.Principals
  alias Biot.Server.Queries.CredentialView
  alias Biot.Server.Repo
  alias Biot.Server.Schema.Credential
  alias Biot.Server.Sessions
  alias Biot.Server.Tokens

  @spec create(Authentication.t() | nil, String.t(), DateTime.t()) ::
          {:ok, Created.t()} | {:error, CommandError.t()}
  def create(nil, _label, _expires_at), do: {:error, :unauthenticated}

  def create(%Authentication{} = authentication, label, %DateTime{} = expires_at) do
    with :ok <- Label.validate(label),
         :ok <- validate_expiry(expires_at) do
      {token, digest} = Tokens.mint("biot_")

      Repo.transact(
        fn repo -> create_credential(repo, authentication, label, expires_at, token, digest) end,
        mode: :immediate
      )
    end
  end

  defp create_credential(repo, authentication, label, expires_at, token, digest) do
    with :ok <- Sessions.require_control(repo, authentication) do
      credential =
        repo.insert!(%Credential{
          id: CredentialId.generate(),
          principal_id: authentication.actor.principal_id,
          label: label,
          secret_digest: digest,
          expires_at: expires_at
        })

      {:ok, %Created{credential: CredentialView.project(credential), token: token}}
    end
  end

  @spec list(Actor.t() | nil) :: {:ok, [CredentialView.t()]} | {:error, CommandError.t()}
  def list(nil), do: {:error, :unauthenticated}

  def list(%Actor{} = actor) do
    with :ok <- Principals.require_enabled(Repo, actor) do
      credentials =
        from(credential in Credential,
          where: credential.principal_id == ^actor.principal_id,
          order_by: [asc: credential.inserted_at, asc: credential.id]
        )
        |> Repo.all()
        |> Enum.map(&CredentialView.project/1)

      {:ok, credentials}
    end
  end

  @spec revoke(Actor.t() | nil, CredentialId.t()) :: :ok | {:error, CommandError.t()}
  def revoke(nil, %CredentialId{}), do: {:error, :unauthenticated}

  def revoke(%Actor{} = actor, %CredentialId{} = credential_id) do
    with :ok <- Principals.require_enabled(Repo, actor) do
      {deleted, _rows} =
        Repo.delete_all(
          from(credential in Credential,
            where:
              credential.id == ^credential_id and credential.principal_id == ^actor.principal_id
          )
        )

      if deleted == 1,
        do: Owners.close_proof({:credential, credential_id}),
        else: {:error, :not_found}
    end
  end

  @spec authenticate(String.t()) :: {:ok, Authentication.t()} | :error
  def authenticate(token) when is_binary(token) do
    case live_credential(Tokens.digest(token)) do
      %Credential{} = credential ->
        touch(credential)

        {:ok,
         %Authentication{
           actor: %Actor{principal_id: credential.principal_id},
           proof: AuthenticationProof.credential(credential.id, credential.expires_at)
         }}

      nil ->
        :error
    end
  end

  @spec sweep_expired(DateTime.t()) :: non_neg_integer()
  def sweep_expired(%DateTime{} = now) do
    {deleted, _rows} =
      Repo.delete_all(from(credential in Credential, where: credential.expires_at <= ^now))

    deleted
  end

  defp validate_expiry(expires_at) do
    now = DateTime.utc_now()
    latest = DateTime.add(now, max_lifetime_ms(), :millisecond)

    cond do
      DateTime.compare(expires_at, now) != :gt ->
        {:error, {:invalid_input, %{expires_at: [:not_future]}}}

      DateTime.compare(expires_at, latest) == :gt ->
        {:error, {:invalid_input, %{expires_at: [:too_far]}}}

      true ->
        :ok
    end
  end

  defp live_credential(digest) do
    Validity.credential_by_digest(Repo, digest, DateTime.utc_now())
  end

  defp touch(%Credential{last_used_at: nil} = credential), do: record_use(credential)

  defp touch(%Credential{last_used_at: last_used_at} = credential) do
    cutoff = DateTime.add(DateTime.utc_now(), -interval_ms(), :millisecond)

    if DateTime.compare(last_used_at, cutoff) == :lt, do: record_use(credential)
  end

  defp record_use(%Credential{} = credential) do
    Repo.update_all(
      from(row in Credential, where: row.id == ^credential.id),
      set: [last_used_at: DateTime.utc_now()]
    )
  end

  defp max_lifetime_ms,
    do: Application.fetch_env!(:biot_server, :credential_max_lifetime_ms)

  defp interval_ms,
    do: Application.fetch_env!(:biot_server, :credential_last_used_interval_ms)
end
