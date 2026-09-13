defmodule Biot.Server.PreviewHandoff do
  @moduledoc """
  Lends one control login to one preview host through a single-use code.

  Begin requires a live control proof and view authority for an active
  publication. Finish consumes the code and inserts the preview session in the
  same transaction, so a code is used at most once.
  """

  import Ecto.Query

  alias Biot.Protocol.{Digest, Hostname, SameOriginPath}
  alias Biot.Server.Access
  alias Biot.Server.Actor
  alias Biot.Server.Authentication
  alias Biot.Server.CommandError
  alias Biot.Server.PreviewHandoff.Finished
  alias Biot.Server.Repo
  alias Biot.Server.Schema.{PreviewHandoff, Session}
  alias Biot.Server.Sessions
  alias Biot.Server.Tokens

  @spec begin(Authentication.t() | nil, Hostname.t(), Digest.t(), SameOriginPath.t()) ::
          {:ok, String.t()} | {:error, CommandError.t()}
  def begin(nil, %Hostname{}, %Digest{}, %SameOriginPath{}), do: {:error, :unauthenticated}

  def begin(
        %Authentication{} = authentication,
        %Hostname{} = hostname,
        %Digest{} = challenge_digest,
        %SameOriginPath{} = return_path
      ) do
    Repo.transact(
      fn repo ->
        with :ok <- Sessions.require_control(repo, authentication),
             :ok <- Access.view_authorized(repo, authentication.actor, hostname) do
          {code, code_digest} = Tokens.mint()

          repo.insert!(%PreviewHandoff{
            code_digest: code_digest,
            hostname: hostname,
            control_session_digest: control_digest(authentication),
            challenge_digest: challenge_digest,
            return_path: return_path,
            expires_at: DateTime.add(DateTime.utc_now(), handoff_ttl_ms(), :millisecond)
          })

          {:ok, code}
        end
      end,
      mode: :immediate
    )
  end

  @spec finish(Hostname.t(), String.t(), String.t()) ::
          {:ok, Finished.t()} | {:error, CommandError.t()}
  def finish(%Hostname{} = hostname, code, challenge)
      when is_binary(code) and is_binary(challenge) do
    Repo.transact(
      fn repo ->
        with %PreviewHandoff{} = handoff <- load_handoff(repo, code),
             :ok <- require_current(handoff, hostname, challenge),
             %Session{} = parent <- Sessions.live_control(repo, handoff.control_session_digest),
             :ok <-
               Access.view_authorized(repo, %Actor{principal_id: parent.principal_id}, hostname) do
          repo.delete!(handoff)

          {token, digest} = Tokens.mint()

          repo.insert!(%Session{
            id_digest: digest,
            principal_id: parent.principal_id,
            scope: :preview,
            hostname: hostname,
            control_session_digest: parent.id_digest,
            expires_at: parent.expires_at
          })

          {:ok, %Finished{token: token, return_path: handoff.return_path}}
        else
          _missing_or_rejected -> {:error, :unauthenticated}
        end
      end,
      mode: :immediate
    )
  end

  @spec sweep_expired(DateTime.t()) :: non_neg_integer()
  def sweep_expired(%DateTime{} = now) do
    {deleted, _rows} =
      Repo.delete_all(from(handoff in PreviewHandoff, where: handoff.expires_at <= ^now))

    deleted
  end

  defp load_handoff(repo, code), do: repo.get(PreviewHandoff, Tokens.digest(code))

  defp require_current(%PreviewHandoff{} = handoff, hostname, challenge) do
    if handoff.hostname == hostname and
         DateTime.compare(handoff.expires_at, DateTime.utc_now()) == :gt and
         Tokens.digest(challenge) == handoff.challenge_digest do
      :ok
    else
      {:error, :unauthenticated}
    end
  end

  defp control_digest(%Authentication{proof: {:control, digest, _expires_at}}), do: digest

  defp handoff_ttl_ms, do: Application.fetch_env!(:biot_server, :preview_handoff_ttl_ms)
end
