defmodule Biot.Server.Sessions do
  @moduledoc """
  Owns control and preview browser sessions.

  `start_control/1` checks the stored principal and inserts the session in one
  immediate transaction. `control/1` and `preview/2` look up a presented token.
  Logout deletes the control row, so previews and handoffs cascade from it.
  Mutation boundaries recheck a control proof with `require_control/2`.
  """

  import Ecto.Query

  alias Biot.Protocol.{Digest, Hostname, PrincipalId}
  alias Biot.Server.Actor
  alias Biot.Server.Authentication
  alias Biot.Server.AuthenticationProof
  alias Biot.Server.Principals
  alias Biot.Server.Repo
  alias Biot.Server.Schema.{Principal, Session}
  alias Biot.Server.Tokens

  @spec start_control(PrincipalId.t()) :: {:ok, String.t()} | {:error, :unauthenticated}
  def start_control(%PrincipalId{} = principal_id) do
    {token, digest} = Tokens.mint()

    Repo.transact(
      fn repo ->
        with :ok <- Principals.require_enabled(repo, actor(principal_id)) do
          expires_at = DateTime.add(DateTime.utc_now(), lifetime_ms(), :millisecond)

          repo.insert!(%Session{
            id_digest: digest,
            principal_id: principal_id,
            scope: :control,
            expires_at: expires_at
          })

          {:ok, token}
        end
      end,
      mode: :immediate
    )
  end

  @doc """
  Returns the live control session for a digest, or nil.

  Live means a control row, unexpired at one clock reading, with an enabled
  principal. This is the one owner of control-proof validity.
  """
  @spec live_control(Ecto.Repo.t() | module(), Digest.t()) :: Session.t() | nil
  def live_control(repo, digest) do
    now = DateTime.utc_now()

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

  @spec control(String.t()) :: {:ok, Authentication.t()} | :error
  def control(token) when is_binary(token) do
    case live_control(Repo, Tokens.digest(token)) do
      %Session{} = session -> {:ok, control_authentication(session)}
      nil -> :error
    end
  end

  @spec preview(Hostname.t(), String.t()) :: {:ok, Authentication.t()} | :error
  def preview(%Hostname{} = hostname, token) when is_binary(token) do
    # A preview session expires with its parent, so the parent's liveness is
    # the only expiry check the lookup needs.
    with %Session{scope: :preview, hostname: ^hostname, control_session_digest: parent_digest} =
           session <- Repo.get(Session, Tokens.digest(token)),
         %Session{principal_id: principal_id} = parent <- live_control(Repo, parent_digest),
         true <- principal_id == session.principal_id do
      {:ok,
       %Authentication{
         actor: actor(principal_id),
         proof:
           AuthenticationProof.preview(
             session.id_digest,
             parent.id_digest,
             session.hostname,
             session.expires_at
           )
       }}
    else
      _missing_or_rejected -> :error
    end
  end

  @doc """
  Rechecks a control proof on the caller's connection.

  A mutation boundary must not trust the proof tuple. This reads the stored
  live session and requires the same principal.
  """
  @spec require_control(Ecto.Repo.t() | module(), Authentication.t()) ::
          :ok | {:error, :unauthenticated}
  def require_control(repo, %Authentication{actor: actor, proof: {:control, digest, _}}) do
    case live_control(repo, digest) do
      %Session{principal_id: principal_id} when principal_id == actor.principal_id -> :ok
      _missing_or_mismatched -> {:error, :unauthenticated}
    end
  end

  def require_control(_repo, %Authentication{}), do: {:error, :unauthenticated}

  @spec logout(String.t()) :: :ok | {:error, :unauthenticated}
  def logout(token) when is_binary(token) do
    digest = Tokens.digest(token)

    with {:ok, :ok} <-
           Repo.transact(fn repo -> delete_control_session(repo, digest) end, mode: :immediate) do
      :ok
    end
  end

  @spec sweep_expired(DateTime.t()) :: non_neg_integer()
  def sweep_expired(%DateTime{} = now) do
    {deleted, _rows} =
      Repo.delete_all(from(session in Session, where: session.expires_at <= ^now))

    deleted
  end

  defp delete_control_session(repo, digest) do
    case live_control(repo, digest) do
      %Session{} = session ->
        repo.delete_all(from(s in Session, where: s.id_digest == ^session.id_digest))
        {:ok, :ok}

      nil ->
        {:error, :unauthenticated}
    end
  end

  defp control_authentication(%Session{} = session) do
    %Authentication{
      actor: actor(session.principal_id),
      proof: AuthenticationProof.control(session.id_digest, session.expires_at)
    }
  end

  defp actor(principal_id), do: %Actor{principal_id: principal_id}

  defp lifetime_ms, do: Application.fetch_env!(:biot_server, :control_session_lifetime_ms)
end
