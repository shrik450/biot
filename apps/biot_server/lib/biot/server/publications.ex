defmodule Biot.Server.Publications do
  @moduledoc """
  Owns published ports and their stable hostnames.

  A withdrawal deletes the view grants for each affected port. A view grant exists only for an
  active publication, so the delete shares the transaction.
  """

  import Ecto.Query

  alias Biot.Protocol.{BiotId, Port}
  alias Biot.Server.Access
  alias Biot.Server.Actor
  alias Biot.Server.CommandError
  alias Biot.Server.Policy
  alias Biot.Server.Policy.Transaction
  alias Biot.Server.Publications.Hostname
  alias Biot.Server.Queries.PublicationView
  alias Biot.Server.Repo
  alias Biot.Server.Schema.{Biot, Publication, ViewGrant}

  # Shared with the migration as "publications_hostname_index". SQLite reports this adapter name.
  @hostname_index_name "publications_hostname_index"

  @spec publish(Actor.t() | nil, BiotId.t(), Port.t()) :: Policy.result()
  def publish(nil, %BiotId{}, %Port{}), do: {:error, :unauthenticated}

  def publish(%Actor{} = actor, %BiotId{} = biot_id, %Port{} = port) do
    Transaction.execute(actor, biot_id, fn repo, biot ->
      publish_change(repo, biot, port)
    end)
  end

  @spec unpublish(Actor.t() | nil, BiotId.t(), Port.t()) :: Policy.result()
  def unpublish(nil, %BiotId{}, %Port{}), do: {:error, :unauthenticated}

  def unpublish(%Actor{} = actor, %BiotId{} = biot_id, %Port{} = port) do
    Transaction.execute(actor, biot_id, fn repo, biot ->
      unpublish_change(repo, biot, port)
    end)
  end

  @spec discover(Actor.t() | nil, BiotId.t()) ::
          {:ok, [PublicationView.t()]} | {:error, CommandError.t()}
  def discover(nil, %BiotId{}), do: {:error, :unauthenticated}

  def discover(%Actor{} = actor, %BiotId{} = biot_id) do
    domain = Application.fetch_env!(:biot_server, :publication_domain)

    with {:ok, biot, role} <- Access.fetch_readable(actor, biot_id) do
      publications =
        active_for([biot.id])
        |> Map.get(biot.id, [])
        |> PublicationView.visible(role)

      {:ok, PublicationView.project(publications, domain)}
    end
  end

  @spec active?(module(), BiotId.t(), Port.t()) :: boolean()
  def active?(repo, %BiotId{} = biot_id, %Port{} = port) do
    active_publications()
    |> where(
      [publication],
      publication.biot_id == ^biot_id and publication.port == ^port
    )
    |> repo.exists?()
  end

  @spec active_for([BiotId.t()]) :: %{BiotId.t() => [Publication.t()]}
  def active_for([]), do: %{}

  def active_for(biot_ids) do
    active_publications()
    |> where([publication], publication.biot_id in ^biot_ids)
    |> Repo.all()
    |> Enum.group_by(& &1.biot_id)
  end

  @spec withdraw_all(Ecto.Multi.t(), BiotId.t()) :: Ecto.Multi.t()
  def withdraw_all(multi, %BiotId{} = biot_id) do
    multi
    |> Ecto.Multi.update_all(
      :deactivate_publications,
      from(publication in Publication, where: publication.biot_id == ^biot_id),
      set: [state: :inactive]
    )
    |> Ecto.Multi.delete_all(
      :delete_view_grants,
      from(grant in ViewGrant, where: grant.biot_id == ^biot_id)
    )
  end

  defp publish_change(repo, %Biot{} = biot, port) do
    case repo.get_by(Publication, biot_id: biot.id, port: port) do
      %Publication{state: :active} ->
        :unchanged

      %Publication{state: :inactive} = publication ->
        {:added,
         Ecto.Multi.new()
         |> Ecto.Multi.update(
           :activate_publication,
           Ecto.Changeset.change(publication, state: :active)
         )}

      nil ->
        publication = %Publication{
          biot_id: biot.id,
          port: port,
          hostname: Hostname.allocate(),
          state: :active
        }

        multi =
          Ecto.Multi.new()
          |> Ecto.Multi.run(:insert_publication, fn repo, _changes ->
            insert_publication(repo, publication_changeset(publication))
          end)

        {:added, multi}
    end
  end

  defp unpublish_change(repo, %Biot{} = biot, port) do
    case repo.get_by(Publication, biot_id: biot.id, port: port) do
      nil ->
        :unchanged

      %Publication{state: :inactive} ->
        :unchanged

      %Publication{state: :active} = publication ->
        multi =
          Ecto.Multi.new()
          |> Ecto.Multi.update(
            :deactivate_publication,
            Ecto.Changeset.change(publication, state: :inactive)
          )
          |> Ecto.Multi.delete_all(
            :delete_view_grants,
            from(grant in ViewGrant,
              where: grant.biot_id == ^biot.id and grant.port == ^port
            )
          )

        {:withdrawn, multi}
    end
  end

  defp insert_publication(repo, changeset) do
    case repo.insert(changeset) do
      {:ok, publication} ->
        {:ok, publication}

      {:error, %Ecto.Changeset{errors: [hostname: _error]}} ->
        {:error, :hostname_conflict}

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError,
          action: changeset.action || :insert,
          changeset: changeset
    end
  end

  defp publication_changeset(publication) do
    publication
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:hostname, name: @hostname_index_name)
  end

  defp active_publications do
    from(publication in Publication, where: publication.state == :active)
  end
end
