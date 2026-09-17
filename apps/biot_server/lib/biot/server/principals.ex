defmodule Biot.Server.Principals do
  @moduledoc """
  Owns principal identity, the actor's own principal view, operator disabling, and last-seen email
  lookup.
  """

  import Ecto.Query

  require Logger

  alias Biot.Protocol.PrincipalId
  alias Biot.Server.Actor
  alias Biot.Server.CommandError
  alias Biot.Server.CommitEffects
  alias Biot.Server.Principals.DisabledIdentities
  alias Biot.Server.Queries.PrincipalView
  alias Biot.Server.Repo
  alias Biot.Server.Schema.Biot, as: BiotRow
  alias Biot.Server.Schema.{Credential, Principal, Session, ShellGrant, SshKey, ViewGrant}

  @type rejection :: DisabledIdentities.error()

  @spec identify(String.t(), String.t(), %{email: String.t() | nil, name: String.t() | nil}) ::
          {:ok, Principal.t()} | {:error, CommandError.t()}
  def identify(issuer, subject, %{email: email, name: name})
      when is_binary(issuer) and is_binary(subject) and
             (is_binary(email) or is_nil(email)) and (is_binary(name) or is_nil(name)) do
    # Immediate mode takes SQLite write ownership before identity is read.
    Repo.transact(
      fn repo ->
        case repo.one(
               from(principal in Principal,
                 where: principal.issuer == ^issuer and principal.subject == ^subject
               )
             ) do
          nil -> insert(repo, issuer, subject, email, name)
          principal -> update_last_seen(repo, principal, email, name)
        end
      end,
      mode: :immediate
    )
  end

  def identify(_issuer, _subject, _claims) do
    CommandError.invalid_input(%{identity: [:invalid_format]})
  end

  @spec reload() :: :ok | {:error, rejection()}
  def reload do
    with {:ok, identities} <- DisabledIdentities.load(),
         :ok <- apply_disabled_identities(identities) do
      :ok
    else
      {:error, rejection} ->
        Logger.warning("principal reload failed: #{message(rejection)}")
        {:error, rejection}
    end
  end

  @spec message(rejection()) :: String.t()
  def message(rejection), do: DisabledIdentities.message(rejection)

  @spec require_enabled(Ecto.Repo.t() | module(), Actor.t()) ::
          :ok | {:error, :unauthenticated}
  def require_enabled(repo, %Actor{principal_id: principal_id}) do
    if repo.exists?(
         from(principal in Principal,
           where: principal.id == ^principal_id and principal.status == :enabled
         )
       ) do
      :ok
    else
      {:error, :unauthenticated}
    end
  end

  @spec get(Actor.t() | nil) :: {:ok, PrincipalView.t()} | {:error, CommandError.t()}
  def get(nil), do: {:error, :unauthenticated}

  def get(%Actor{principal_id: principal_id} = actor) do
    with :ok <- require_enabled(Repo, actor) do
      # Principals are never deleted, so the enabled principal's row is still present.
      {:ok, PrincipalView.project(Repo.get!(Principal, principal_id))}
    end
  end

  @spec resolve_email(Actor.t() | nil, String.t()) ::
          {:ok, PrincipalId.t()} | {:error, :not_found | :unauthenticated}
  def resolve_email(%Actor{} = actor, email) when is_binary(email) do
    with :ok <- require_enabled(Repo, actor) do
      ids =
        from(principal in Principal,
          where: principal.last_seen_email == ^email,
          order_by: [asc: principal.inserted_at],
          limit: 2,
          select: principal.id
        )
        |> Repo.all()

      case ids do
        [principal_id] -> {:ok, principal_id}
        _none_or_ambiguous -> {:error, :not_found}
      end
    end
  end

  def resolve_email(_actor, _email), do: {:error, :unauthenticated}

  defp apply_disabled_identities(identities) do
    {:ok, {disabled_ids, wakes}} =
      Repo.transact(fn repo -> change_principals(repo, identities) end, mode: :immediate)

    CommitEffects.enforce(%CommitEffects{
      owners: Enum.map(disabled_ids, &{:principal, &1}),
      wakes: wakes,
      readers: Enum.map(wakes, &elem(&1, 1))
    })
  end

  defp change_principals(repo, identities) do
    configured = MapSet.new(identities, &{&1.issuer, &1.subject})
    configured_rows = configured_principals(repo, MapSet.to_list(configured))
    existing = MapSet.new(configured_rows, &{&1.issuer, &1.subject})
    to_disable = Enum.filter(configured_rows, &(&1.status == :enabled))

    to_enable =
      repo.all(from(principal in Principal, where: principal.status == :disabled))
      |> Enum.reject(&MapSet.member?(configured, {&1.issuer, &1.subject}))

    Enum.each(to_disable, &disable_principal(repo, &1))
    Enum.each(to_enable, &enable_principal(repo, &1))

    configured
    |> Enum.reject(&MapSet.member?(existing, &1))
    |> Enum.each(fn {issuer, subject} -> insert_disabled(repo, issuer, subject) end)

    {:ok, {Enum.map(to_disable, & &1.id), bump_affected_biots(repo, to_disable)}}
  end

  defp configured_principals(_repo, []), do: []

  defp configured_principals(repo, identities) do
    identities
    |> Enum.reduce(from(principal in Principal), fn {issuer, subject}, query ->
      or_where(query, [principal], principal.issuer == ^issuer and principal.subject == ^subject)
    end)
    |> repo.all()
  end

  defp insert_disabled(repo, issuer, subject) do
    repo.insert!(%Principal{
      id: PrincipalId.generate(),
      issuer: issuer,
      subject: subject,
      status: :disabled
    })
  end

  defp disable_principal(repo, principal) do
    repo.update!(Ecto.Changeset.change(principal, status: :disabled))

    repo.delete_all(from(session in Session, where: session.principal_id == ^principal.id))

    repo.delete_all(
      from(credential in Credential, where: credential.principal_id == ^principal.id)
    )

    repo.delete_all(from(key in SshKey, where: key.principal_id == ^principal.id))
  end

  defp enable_principal(repo, principal) do
    repo.update!(Ecto.Changeset.change(principal, status: :enabled))
  end

  defp bump_affected_biots(_repo, []), do: []

  defp bump_affected_biots(repo, principals) do
    principal_ids = Enum.map(principals, & &1.id)

    {_count, wake} =
      from(biot in BiotRow,
        where:
          biot.owner_id in ^principal_ids or
            biot.id in subquery(
              from(grant in ShellGrant,
                where: grant.principal_id in ^principal_ids,
                select: grant.biot_id
              )
            ) or
            biot.id in subquery(
              from(grant in ViewGrant,
                where: grant.principal_id in ^principal_ids,
                select: grant.biot_id
              )
            ),
        select: {biot.node_id, biot.id}
      )
      |> repo.update_all(inc: [access_revision: 1])

    wake
  end

  defp insert(repo, issuer, subject, email, name) do
    %Principal{
      id: PrincipalId.generate(),
      issuer: issuer,
      subject: subject,
      last_seen_email: email,
      last_seen_name: name
    }
    |> repo.insert()
    |> map_write_result()
  end

  defp update_last_seen(repo, principal, email, name) do
    principal
    |> Ecto.Changeset.change(last_seen_email: email, last_seen_name: name)
    |> repo.update()
    |> map_write_result()
  end

  defp map_write_result({:ok, principal}), do: {:ok, principal}
  defp map_write_result({:error, _changeset}), do: {:error, :temporarily_unavailable}
end
