defmodule Biot.Server.Access do
  @moduledoc "Owns access grants and the rule for which Biots an actor may read."

  import Ecto.Query

  alias Biot.Protocol.{BiotId, Port, PrincipalId}
  alias Biot.Server.Actor
  alias Biot.Server.Authorization
  alias Biot.Server.CommandError
  alias Biot.Server.Policy
  alias Biot.Server.Policy.Transaction
  alias Biot.Server.Publications
  alias Biot.Server.Queries.AccessView
  alias Biot.Server.Queries.AccessView.Input
  alias Biot.Server.Repo
  alias Biot.Server.Schema.{Biot, Principal, ShellGrant, ViewGrant}

  @spec readable(Ecto.Queryable.t(), Actor.t()) :: Ecto.Query.t()
  def readable(queryable, %Actor{principal_id: principal_id}) do
    shell_grant =
      from(grant in ShellGrant,
        where:
          grant.biot_id == parent_as(:readable_biot).id and
            grant.principal_id == ^principal_id,
        select: 1
      )

    view_grant =
      from(grant in ViewGrant,
        where:
          grant.biot_id == parent_as(:readable_biot).id and
            grant.principal_id == ^principal_id,
        select: 1
      )

    from(biot in queryable,
      as: :readable_biot,
      where:
        biot.owner_id == ^principal_id or exists(subquery(shell_grant)) or
          exists(subquery(view_grant))
    )
  end

  @spec fetch_readable(Actor.t(), BiotId.t()) ::
          {:ok, Biot.t(), Authorization.role()} | {:error, :not_found | :forbidden}
  def fetch_readable(%Actor{} = actor, %BiotId{} = biot_id) do
    query = from(biot in Biot, where: biot.id == ^biot_id)

    case query |> readable(actor) |> Repo.one() do
      %Biot{} = biot ->
        grants = Map.fetch!(grants_for(actor, [biot.id]), biot.id)
        {:ok, biot, Authorization.role(actor, biot, grants)}

      nil ->
        if Repo.exists?(query), do: {:error, :forbidden}, else: {:error, :not_found}
    end
  end

  @doc "Returns an entry for every requested Biot ID, so callers can use Map.fetch!/2."
  @spec grants_for(Actor.t(), [BiotId.t()]) :: %{BiotId.t() => Authorization.grants()}
  def grants_for(%Actor{}, []), do: %{}

  def grants_for(%Actor{} = actor, biot_ids) do
    shell_biot_ids =
      from(grant in ShellGrant,
        where: grant.biot_id in ^biot_ids and grant.principal_id == ^actor.principal_id,
        select: grant.biot_id
      )
      |> Repo.all()
      |> MapSet.new()

    view_ports =
      from(grant in ViewGrant,
        where: grant.biot_id in ^biot_ids and grant.principal_id == ^actor.principal_id,
        select: {grant.biot_id, grant.port}
      )
      |> Repo.all()
      |> Enum.group_by(fn {biot_id, _port} -> biot_id end, fn {_biot_id, port} -> port end)

    Map.new(biot_ids, fn biot_id ->
      ports = view_ports |> Map.get(biot_id, []) |> Enum.sort_by(& &1.value)
      {biot_id, %{shell: MapSet.member?(shell_biot_ids, biot_id), view_ports: ports}}
    end)
  end

  @spec revoke_shell_grants(Ecto.Multi.t(), BiotId.t()) :: Ecto.Multi.t()
  def revoke_shell_grants(multi, %BiotId{} = biot_id) do
    Ecto.Multi.delete_all(
      multi,
      :delete_shell_grants,
      from(grant in ShellGrant, where: grant.biot_id == ^biot_id)
    )
  end

  @spec grant_shell(Actor.t() | nil, BiotId.t(), PrincipalId.t()) :: Policy.result()
  def grant_shell(nil, %BiotId{}, %PrincipalId{}), do: {:error, :unauthenticated}

  def grant_shell(%Actor{} = actor, %BiotId{} = biot_id, %PrincipalId{} = principal_id) do
    Transaction.execute(actor, biot_id, fn repo, biot ->
      grant_shell_change(repo, biot, principal_id)
    end)
  end

  @spec revoke_shell(Actor.t() | nil, BiotId.t(), PrincipalId.t()) :: Policy.result()
  def revoke_shell(nil, %BiotId{}, %PrincipalId{}), do: {:error, :unauthenticated}

  def revoke_shell(%Actor{} = actor, %BiotId{} = biot_id, %PrincipalId{} = principal_id) do
    Transaction.execute(actor, biot_id, fn repo, biot ->
      revoke_shell_change(repo, biot, principal_id)
    end)
  end

  @spec grant_view(Actor.t() | nil, BiotId.t(), Port.t(), PrincipalId.t()) :: Policy.result()
  def grant_view(nil, %BiotId{}, %Port{}, %PrincipalId{}), do: {:error, :unauthenticated}

  def grant_view(
        %Actor{} = actor,
        %BiotId{} = biot_id,
        %Port{} = port,
        %PrincipalId{} = principal_id
      ) do
    Transaction.execute(actor, biot_id, fn repo, biot ->
      grant_view_change(repo, biot, port, principal_id)
    end)
  end

  @spec revoke_view(Actor.t() | nil, BiotId.t(), Port.t(), PrincipalId.t()) :: Policy.result()
  def revoke_view(nil, %BiotId{}, %Port{}, %PrincipalId{}), do: {:error, :unauthenticated}

  def revoke_view(
        %Actor{} = actor,
        %BiotId{} = biot_id,
        %Port{} = port,
        %PrincipalId{} = principal_id
      ) do
    Transaction.execute(actor, biot_id, fn repo, biot ->
      revoke_view_change(repo, biot, port, principal_id)
    end)
  end

  @spec get_grants(Actor.t() | nil, BiotId.t()) ::
          {:ok, AccessView.t()} | {:error, CommandError.t()}
  def get_grants(nil, %BiotId{}), do: {:error, :unauthenticated}

  def get_grants(%Actor{} = actor, %BiotId{} = biot_id) do
    case Repo.get(Biot, biot_id) do
      nil ->
        {:error, :not_found}

      %Biot{} = biot ->
        if Authorization.may_read_grants?(actor, biot) do
          shell_grants = Repo.all(from(grant in ShellGrant, where: grant.biot_id == ^biot_id))
          view_grants = Repo.all(from(grant in ViewGrant, where: grant.biot_id == ^biot_id))

          {:ok,
           AccessView.project(%Input{
             biot: biot,
             shell_grants: shell_grants,
             view_grants: view_grants
           })}
        else
          {:error, :forbidden}
        end
    end
  end

  defp grant_shell_change(repo, %Biot{} = biot, principal_id) do
    with :ok <- require_principal(repo, principal_id) do
      case repo.get_by(ShellGrant, biot_id: biot.id, principal_id: principal_id) do
        %ShellGrant{} ->
          :unchanged

        nil ->
          grant = %ShellGrant{biot_id: biot.id, principal_id: principal_id}

          {:added,
           Ecto.Multi.insert(Ecto.Multi.new(), :shell_grant, shell_grant_changeset(grant))}
      end
    end
  end

  defp revoke_shell_change(repo, %Biot{} = biot, principal_id) do
    case repo.get_by(ShellGrant, biot_id: biot.id, principal_id: principal_id) do
      nil ->
        :unchanged

      %ShellGrant{} = grant ->
        {:withdrawn, Ecto.Multi.delete(Ecto.Multi.new(), :shell_grant, grant)}
    end
  end

  defp grant_view_change(repo, %Biot{} = biot, port, principal_id) do
    with :ok <- require_principal(repo, principal_id),
         :ok <- require_publication(repo, biot.id, port) do
      case repo.get_by(ViewGrant,
             biot_id: biot.id,
             port: port,
             principal_id: principal_id
           ) do
        %ViewGrant{} ->
          :unchanged

        nil ->
          grant = %ViewGrant{biot_id: biot.id, port: port, principal_id: principal_id}
          {:added, Ecto.Multi.insert(Ecto.Multi.new(), :view_grant, view_grant_changeset(grant))}
      end
    end
  end

  defp revoke_view_change(repo, %Biot{} = biot, port, principal_id) do
    case repo.get_by(ViewGrant,
           biot_id: biot.id,
           port: port,
           principal_id: principal_id
         ) do
      nil ->
        :unchanged

      %ViewGrant{} = grant ->
        {:withdrawn, Ecto.Multi.delete(Ecto.Multi.new(), :view_grant, grant)}
    end
  end

  defp require_principal(repo, principal_id) do
    if repo.exists?(from(principal in Principal, where: principal.id == ^principal_id)),
      do: :ok,
      else: {:error, :not_found}
  end

  defp require_publication(repo, biot_id, port) do
    if Publications.active?(repo, biot_id, port),
      do: :ok,
      else: {:error, :not_found}
  end

  defp shell_grant_changeset(grant) do
    grant
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:principal_id, name: :shell_grant)
  end

  defp view_grant_changeset(grant) do
    grant
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:principal_id, name: :view_grant)
  end
end
