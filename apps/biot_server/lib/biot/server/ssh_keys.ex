defmodule Biot.Server.SshKeys do
  @moduledoc """
  Owns registered SSH public keys.

  A key is registered under one principal. Registration rejects a fingerprint
  already held by anyone. Authentication reads the stored key back, so a removed
  key stops working on the next channel.
  """

  import Ecto.Query

  alias Biot.Protocol.{SshKeyId, SshPublicKey}
  alias Biot.Server.Access.Owners
  alias Biot.Server.Actor
  alias Biot.Server.Authentication
  alias Biot.Server.Authentication.Validity
  alias Biot.Server.AuthenticationProof
  alias Biot.Server.CommandError
  alias Biot.Server.Label
  alias Biot.Server.Principals
  alias Biot.Server.Queries.SshKeyView
  alias Biot.Server.Repo
  alias Biot.Server.Schema.SshKey
  alias Biot.Server.Ssh.Authentications

  @spec add(Actor.t() | nil, String.t(), String.t()) ::
          {:ok, SshKeyView.t()} | {:error, CommandError.t()}
  def add(nil, _line, _label), do: {:error, :unauthenticated}

  def add(%Actor{} = actor, line, label) do
    with {:ok, public_key} <- parse_public_key(line),
         :ok <- Label.validate(label) do
      Repo.transact(fn repo -> insert_key(repo, actor, public_key, label) end, mode: :immediate)
    end
  end

  @spec list(Actor.t() | nil) :: {:ok, [SshKeyView.t()]} | {:error, CommandError.t()}
  def list(nil), do: {:error, :unauthenticated}

  def list(%Actor{} = actor) do
    with :ok <- Principals.require_enabled(Repo, actor) do
      keys =
        from(key in SshKey,
          where: key.principal_id == ^actor.principal_id,
          order_by: [asc: key.inserted_at, asc: key.id]
        )
        |> Repo.all()
        |> Enum.map(&SshKeyView.project/1)

      {:ok, keys}
    end
  end

  @spec remove(Actor.t() | nil, SshKeyId.t()) :: :ok | {:error, CommandError.t()}
  def remove(nil, %SshKeyId{}), do: {:error, :unauthenticated}

  def remove(%Actor{} = actor, %SshKeyId{} = key_id) do
    with :ok <- Principals.require_enabled(Repo, actor) do
      {deleted, _rows} =
        Repo.delete_all(
          from(key in SshKey,
            where: key.id == ^key_id and key.principal_id == ^actor.principal_id
          )
        )

      if deleted == 1, do: remove_key(key_id), else: {:error, :not_found}
    end
  end

  defp remove_key(key_id) do
    Owners.close_proof({:ssh_key, key_id})
    # Socket teardown must not block the API request that removed the key.
    {:ok, _pid} = Task.start(fn -> close_connections(key_id) end)
    :ok
  end

  # A removed key usually means a lost device, so the connection itself goes, not only the
  # channels it holds. Each channel also closes its stream through its owner registration.
  defp close_connections(key_id) do
    key_id
    |> Authentications.connections()
    |> Enum.each(fn connection ->
      if Process.alive?(connection), do: safe_close(connection)
    end)
  end

  defp safe_close(connection) do
    :ssh.close(connection)
  catch
    _kind, _reason -> :ok
  end

  @spec authenticate(SshPublicKey.t()) :: {:ok, Authentication.t()} | :error
  def authenticate(%SshPublicKey{} = public_key) do
    case Validity.ssh_key_by_fingerprint(Repo, public_key.fingerprint) do
      %SshKey{} = key ->
        {:ok,
         %Authentication{
           actor: %Actor{principal_id: key.principal_id},
           proof: AuthenticationProof.ssh_key(key.id)
         }}

      _unknown_or_rejected ->
        :error
    end
  end

  defp insert_key(repo, actor, public_key, label) do
    with :ok <- Principals.require_enabled(repo, actor) do
      key = %SshKey{
        id: SshKeyId.generate(),
        principal_id: actor.principal_id,
        public_key: public_key,
        fingerprint: public_key.fingerprint,
        label: label
      }

      key
      |> Ecto.Changeset.change()
      # Ecto's default name matches because ecto_sqlite3 names a unique
      # violation by table and column, not by the index.
      |> Ecto.Changeset.unique_constraint(:fingerprint)
      |> repo.insert()
      |> insert_result()
    end
  end

  defp insert_result({:ok, key}), do: {:ok, SshKeyView.project(key)}

  defp insert_result({:error, %Ecto.Changeset{errors: [fingerprint: _error]}}) do
    CommandError.invalid_input(%{public_key: [:already_registered]})
  end

  defp insert_result({:error, changeset}) do
    raise Ecto.InvalidChangesetError,
      action: changeset.action || :insert,
      changeset: changeset
  end

  defp parse_public_key(line) do
    case SshPublicKey.parse(line) do
      {:ok, public_key} -> {:ok, public_key}
      {:error, :invalid_format} -> CommandError.invalid_input(%{public_key: [:invalid_format]})
    end
  end
end
