defmodule Biot.Server.Publications do
  @moduledoc "Owns published ports and their stable hostnames."

  import Ecto.Query

  alias Biot.Protocol.{BiotId, Port}
  alias Biot.Server.Actor
  alias Biot.Server.Authorization
  alias Biot.Server.CommandError
  alias Biot.Server.Policy
  alias Biot.Server.Policy.Transaction
  alias Biot.Server.Publications.HostnameDerivation
  alias Biot.Server.Queries.PublicationView
  alias Biot.Server.Repo
  alias Biot.Server.Schema.{Biot, Publication, ShellGrant}

  # Shared with the migration as "publications_hostname_index". SQLite reports this adapter name.
  @hostname_index_name "publications_hostname_index"

  @spec publish(Actor.t() | nil, BiotId.t(), Port.t()) :: Policy.result()
  def publish(nil, %BiotId{}, %Port{}), do: {:error, :unauthenticated}

  def publish(%Actor{} = actor, %BiotId{} = biot_id, %Port{} = port) do
    key = Application.fetch_env!(:biot_server, :publication_hmac_key)

    Transaction.execute(actor, biot_id, fn repo, biot ->
      publish_change(repo, biot, port, key)
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

    with {:ok, biot} <- load_biot(biot_id),
         :ok <- authorize_discovery(actor, biot) do
      publications = Repo.all(publications_query(biot_id))
      {:ok, PublicationView.project(publications, domain)}
    end
  end

  defp publish_change(repo, %Biot{} = biot, port, key) do
    case repo.get_by(Publication, biot_id: biot.id, port: port) do
      %Publication{} ->
        :unchanged

      nil ->
        publication = %Publication{
          biot_id: biot.id,
          port: port,
          hostname: HostnameDerivation.derive(biot.id, port, key)
        }

        multi =
          Ecto.Multi.new()
          |> Ecto.Multi.run(:publication, fn repo, _changes ->
            insert_publication(repo, publication_changeset(publication))
          end)

        {:added, multi}
    end
  end

  defp unpublish_change(repo, %Biot{} = biot, port) do
    case repo.get_by(Publication, biot_id: biot.id, port: port) do
      nil ->
        :unchanged

      %Publication{} = publication ->
        multi =
          Ecto.Multi.new()
          # The foreign key cascade removes the publication's view grants.
          |> Ecto.Multi.delete(:publication, publication)

        {:withdrawn, multi}
    end
  end

  defp insert_publication(repo, changeset) do
    case repo.insert(changeset) do
      {:ok, publication} ->
        {:ok, publication}

      {:error, changeset} ->
        if hostname_conflict?(changeset) do
          {:error, :hostname_conflict}
        else
          raise Ecto.InvalidChangesetError,
            action: changeset.action || :insert,
            changeset: changeset
        end
    end
  end

  defp publication_changeset(publication) do
    publication
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:hostname, name: @hostname_index_name)
  end

  defp hostname_conflict?(changeset) do
    Enum.any?(changeset.errors, fn
      {:hostname, {_message, metadata}} ->
        metadata[:constraint] == :unique and
          metadata[:constraint_name] == @hostname_index_name

      _error ->
        false
    end)
  end

  defp load_biot(biot_id) do
    case Repo.get(Biot, biot_id) do
      nil -> {:error, :not_found}
      %Biot{} = biot -> {:ok, biot}
    end
  end

  defp authorize_discovery(actor, %Biot{} = biot) do
    if Authorization.owner?(actor, biot) do
      :ok
    else
      shell_grants =
        from(grant in ShellGrant,
          where: grant.biot_id == ^biot.id,
          select: grant.principal_id
        )
        |> Repo.all()

      if Authorization.may_discover?(actor, biot, shell_grants),
        do: :ok,
        else: {:error, :forbidden}
    end
  end

  defp publications_query(biot_id) do
    from(publication in Publication, where: publication.biot_id == ^biot_id)
  end
end
