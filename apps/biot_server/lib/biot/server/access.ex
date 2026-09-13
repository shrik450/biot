defmodule Biot.Server.Access do
  @moduledoc """
  Owns access grants, the rules for which Biots an actor may read and view, and the policy
  reads for stream admission.

  A session owner is the process that holds one stream. It uses only this module for the whole
  lifecycle of that stream:

  1. `open_preview/2` or `open_shell/3` admits the process and returns its stream.
  2. While it holds the stream, the owner passes every message it receives to
     `handle_owner_message/2` first. `{:closed, reason}` means the stream is already closed.
     `:ignored` means the owner passes the message on to `Streams.stream/2`.
  3. When the owner stops holding the stream for any other reason, it calls `close/1`. This
     includes a stream that `Streams.stream/2` reports as ended.

  One process holds one admission at a time, so it must finish step 2 or 3 before it admits
  again. `open_preview/2` and `open_shell/3` build each proof-and-policy snapshot here.
  `Access.Admission` runs the session-owner protocol around that snapshot.
  """

  import Ecto.Query

  alias Biot.Protocol.{BiotId, Hostname, Port, PrincipalId, ShellRequest}
  alias Biot.Server.Access.Admission
  alias Biot.Server.Actor
  alias Biot.Server.Authentication
  alias Biot.Server.Authentication.Validity
  alias Biot.Server.AuthenticationProof
  alias Biot.Server.Authorization
  alias Biot.Server.CommandError
  alias Biot.Server.Policy
  alias Biot.Server.Policy.Transaction
  alias Biot.Server.Principals
  alias Biot.Server.Publications
  alias Biot.Server.Queries.AccessView
  alias Biot.Server.Queries.AccessView.Input
  alias Biot.Server.Repo
  alias Biot.Server.Streams.Stream
  # `Biot` names the schema from this line on, so every `Biot.Server` alias must come first.
  alias Biot.Server.Schema.{Biot, Node, Principal, Publication, ShellGrant, ViewGrant}

  @doc """
  Narrows `queryable` to the Biots the actor may read, for listings.

  This must match `Authorization.may_read?/3`, which decides one loaded Biot.
  """
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
          {:ok, Biot.t(), Authorization.role()}
          | {:error, :not_found | :forbidden | :unauthenticated}
  def fetch_readable(%Actor{} = actor, %BiotId{} = biot_id) do
    with :ok <- Principals.require_enabled(Repo, actor) do
      readable_biot(actor, biot_id)
    end
  end

  defp readable_biot(actor, biot_id) do
    case Repo.get(Biot, biot_id) do
      nil ->
        {:error, :not_found}

      %Biot{} = biot ->
        grants = Map.fetch!(grants_for(actor, [biot.id]), biot.id)

        with :ok <- allow(Authorization.may_read?(actor, biot, grants)) do
          {:ok, biot, Authorization.role(actor, biot, grants)}
        end
    end
  end

  @doc "Returns an entry for every requested Biot ID, so callers can use Map.fetch!/2."
  @spec grants_for(Actor.t(), [BiotId.t()]) :: %{BiotId.t() => Authorization.grants()}
  def grants_for(%Actor{} = actor, biot_ids), do: grants_for(Repo, actor, biot_ids)

  defp grants_for(_repo, %Actor{}, []), do: %{}

  defp grants_for(repo, %Actor{} = actor, biot_ids) do
    shell_biot_ids =
      from(grant in ShellGrant,
        where: grant.biot_id in ^biot_ids and grant.principal_id == ^actor.principal_id,
        select: grant.biot_id
      )
      |> repo.all()
      |> MapSet.new()

    view_ports =
      from(grant in ViewGrant,
        where: grant.biot_id in ^biot_ids and grant.principal_id == ^actor.principal_id,
        select: {grant.biot_id, grant.port}
      )
      |> repo.all()
      |> Enum.group_by(fn {biot_id, _port} -> biot_id end, fn {_biot_id, port} -> port end)

    Map.new(biot_ids, fn biot_id ->
      ports = view_ports |> Map.get(biot_id, []) |> Enum.sort_by(& &1.value)
      {biot_id, %{shell: MapSet.member?(shell_biot_ids, biot_id), view_ports: ports}}
    end)
  end

  @doc """
  Returns the active publication at `hostname`, its Biot, and its node when the actor may view it.

  It takes the caller's repo so the read runs inside the caller's transaction.
  """
  @spec view_authority(Ecto.Repo.t() | module(), Actor.t(), Hostname.t()) ::
          {:ok, Publication.t(), Biot.t(), Node.t()} | {:error, :not_found | :forbidden}
  def view_authority(repo, %Actor{} = actor, %Hostname{} = hostname) do
    with {:ok, publication} <- active_publication(repo, hostname),
         {:ok, {biot, node}} <- biot_rows(repo, publication.biot_id),
         grants = Map.fetch!(grants_for(repo, actor, [biot.id]), biot.id),
         :ok <- allow(Authorization.may_view?(actor, biot, publication.port, grants.view_ports)) do
      {:ok, publication, biot, node}
    end
  end

  @doc """
  Admits the calling process as the owner of one preview stream.

  The process must not hold another admission. On success, it holds the stream until
  `handle_owner_message/2` returns `{:closed, reason}` or it calls `close/1`.
  """
  @spec open_preview(Authentication.t(), Hostname.t()) ::
          {:ok, Stream.t()} | {:error, Admission.error()}
  def open_preview(%Authentication{} = authentication, %Hostname{} = hostname) do
    # This lookup finds only the Biot to register under. Each snapshot reads view authority again.
    # A hostname stays on one Biot: it is allocated once, publication hostnames have a unique
    # index, and no code deletes publication rows. So every snapshot's publication is on the Biot
    # this owner registered under.
    case active_publication(Repo, hostname) do
      {:ok, %Publication{biot_id: biot_id}} ->
        Admission.admit(authentication, biot_id, fn repo, now ->
          preview_snapshot(repo, authentication, hostname, now)
        end)

      {:error, :not_found} = not_found ->
        not_found
    end
  end

  @doc """
  Admits the calling process as the owner of one shell stream.

  The process must not hold another admission. On success, it holds the stream until
  `handle_owner_message/2` returns `{:closed, reason}` or it calls `close/1`.
  """
  @spec open_shell(Authentication.t(), BiotId.t(), ShellRequest.t()) ::
          {:ok, Stream.t()} | {:error, Admission.error()}
  def open_shell(
        %Authentication{} = authentication,
        %BiotId{} = biot_id,
        %ShellRequest{} = request
      ) do
    Admission.admit(authentication, biot_id, fn repo, now ->
      shell_snapshot(repo, authentication, biot_id, request, now)
    end)
  end

  @doc """
  Handles one message that an owner receives while it holds a stream.

  It closes the stream and returns `{:closed, reason}` for a policy close, the loss of the node's
  control connection, or the proof's expiry. After that the process may admit again. It returns
  `:ignored` for every other message.
  """
  @spec handle_owner_message(Stream.t(), term()) ::
          {:closed, Admission.owner_reason()} | :ignored
  defdelegate handle_owner_message(stream, message), to: Admission

  @doc """
  Closes an owner's stream and removes its registrations, so the process may admit again.

  This is the only close an owner may use. `Streams.close/1` alone leaves the owner registered,
  and the next admission in the same process then crashes.
  """
  @spec close(Stream.t()) :: :ok
  defdelegate close(stream), to: Admission

  defp preview_snapshot(repo, authentication, hostname, now) do
    with :ok <- accepted_on(authentication, {:preview_host, hostname}),
         {:ok, expires_at} <- Validity.check(repo, authentication, now),
         {:ok, publication, biot, node} <- view_authority(repo, authentication.actor, hostname),
         :ok <- live_biot(biot),
         :ok <- node_accessible(node) do
      {:ok,
       %Admission{
         node_id: node.id,
         access_revision: biot.access_revision,
         target: {:port, publication.port},
         expires_at: expires_at
       }}
    end
  end

  defp shell_snapshot(repo, authentication, biot_id, request, now) do
    with :ok <- accepted_on(authentication, :shell),
         {:ok, expires_at} <- Validity.check(repo, authentication, now),
         {:ok, {biot, node}} <- biot_rows(repo, biot_id),
         grants = Map.fetch!(grants_for(repo, authentication.actor, [biot_id]), biot_id),
         :ok <- allow(Authorization.may_shell?(authentication.actor, biot, grants.shell)),
         :ok <- live_biot(biot),
         :ok <- node_accessible(node) do
      {:ok,
       %Admission{
         node_id: node.id,
         access_revision: biot.access_revision,
         target: {:shell, request},
         expires_at: expires_at
       }}
    end
  end

  defp accepted_on(%Authentication{proof: proof}, surface) do
    if AuthenticationProof.accepted_on?(proof, surface),
      do: :ok,
      else: {:error, :unauthenticated}
  end

  defp active_publication(repo, hostname) do
    case Publications.active_by_hostname(repo, hostname) do
      %Publication{} = publication -> {:ok, publication}
      nil -> {:error, :not_found}
    end
  end

  defp biot_rows(repo, biot_id) do
    query =
      from(biot in Biot,
        join: node in Node,
        on: node.id == biot.node_id,
        where: biot.id == ^biot_id,
        select: {biot, node}
      )

    case repo.one(query) do
      {biot, node} -> {:ok, {biot, node}}
      nil -> {:error, :not_found}
    end
  end

  defp live_biot(%Biot{} = biot) do
    if Biot.desired(biot).state == :destroyed, do: {:error, :not_found}, else: :ok
  end

  defp node_accessible(%Node{status: :enabled}), do: :ok
  defp node_accessible(%Node{}), do: {:error, :node_unavailable}

  defp allow(true), do: :ok
  defp allow(false), do: {:error, :forbidden}

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
    with :ok <- Principals.require_enabled(Repo, actor) do
      own_grants(actor, biot_id)
    end
  end

  defp own_grants(actor, biot_id) do
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
