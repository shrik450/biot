defmodule Biot.Server.SessionsIntegrationTest do
  use Biot.Server.DataCase, async: false

  import Ecto.Query

  alias Biot.Protocol.{Hostname, SameOriginPath, SshKeyId}
  alias Biot.Server.Actor
  alias Biot.Server.Authentication
  alias Biot.Server.AuthenticationProof
  alias Biot.Server.Repo
  alias Biot.Server.Schema.{PreviewHandoff, Principal, Session}
  alias Biot.Server.Sessions
  alias Biot.Server.TestFixtures
  alias Biot.Server.Tokens

  defp future(seconds \\ 3_600), do: DateTime.add(DateTime.utc_now(), seconds, :second)

  defp hostname(value) do
    {:ok, hostname} = Hostname.parse(value)
    hostname
  end

  defp same_origin do
    {:ok, path} = SameOriginPath.parse("/preview/start?step=1")
    path
  end

  defp insert_session(principal, scope, opts \\ []) do
    {token, digest} = Tokens.mint()

    expires_at =
      Keyword.get_lazy(opts, :expires_at, fn ->
        parent_expiry = Keyword.get(opts, :parent_expiry, future())
        if scope == :preview, do: parent_expiry, else: future()
      end)

    session =
      Repo.insert!(%Session{
        id_digest: digest,
        principal_id: principal.id,
        scope: scope,
        hostname: if(scope == :preview, do: Keyword.get(opts, :hostname, hostname("preview"))),
        control_session_digest:
          if(scope == :preview,
            do: Keyword.get(opts, :parent_digest, Tokens.digest(start_control!(principal).token))
          ),
        expires_at: expires_at
      })

    {token, session}
  end

  defp start_control!(principal) do
    {:ok, token} = Sessions.start_control(principal.id)
    %{token: token, digest: Tokens.digest(token)}
  end

  defp expire(session) do
    session
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
    |> Repo.update!()
  end

  describe "start_control/1" do
    test "an enabled principal gets a control session and a lookup finds it" do
      principal = TestFixtures.principal(1)

      assert {:ok, token} = Sessions.start_control(principal.id)
      assert byte_size(token) >= 43

      stored = Repo.get!(Session, Tokens.digest(token))
      assert stored.principal_id == principal.id
      assert stored.scope == :control
      assert stored.hostname == nil
      assert stored.control_session_digest == nil

      assert {:ok,
              %Authentication{
                actor: %Actor{principal_id: id},
                proof: {:control, digest, expires_at}
              }} =
               Sessions.control(token)

      assert id == principal.id
      assert digest == Tokens.digest(token)
      assert DateTime.compare(expires_at, DateTime.utc_now()) == :gt
    end

    test "a disabled principal gets no session and no row is written" do
      principal = TestFixtures.principal(1)
      disable(principal)

      assert Sessions.start_control(principal.id) == {:error, :unauthenticated}
      assert Repo.all(Session) == []
    end

    test "a missing principal gets no session" do
      principal = TestFixtures.principal(1)
      Repo.delete!(principal)

      assert Sessions.start_control(principal.id) == {:error, :unauthenticated}
      assert Repo.all(Session) == []
    end

    test "a stale enabled struct over a stored disabled row cannot start a session" do
      principal = TestFixtures.principal(1)

      Repo.update_all(from(p in Principal, where: p.id == ^principal.id),
        set: [status: :disabled]
      )

      assert Sessions.start_control(principal.id) == {:error, :unauthenticated}
      assert Repo.all(Session) == []
    end

    test "the clear token is never stored" do
      principal = TestFixtures.principal(1)
      {:ok, token} = Sessions.start_control(principal.id)

      stored = Repo.get!(Session, Tokens.digest(token))
      refute token in Map.values(stored)
      assert Map.get(stored, :id_digest) == Tokens.digest(token)
    end
  end

  describe "control/1" do
    test "rejects unknown, malformed, and empty tokens" do
      for token <- ["not-a-real-token", "", "biot_whatever"] do
        assert Sessions.control(token) == :error
      end
    end

    test "rejects an expired control session" do
      principal = TestFixtures.principal(1)
      {token, session} = insert_session(principal, :control)
      expire(session)

      assert Sessions.control(token) == :error
    end

    test "rejects a control session whose principal is disabled" do
      principal = TestFixtures.principal(1)
      {token, _session} = insert_session(principal, :control)
      disable(principal)

      assert Sessions.control(token) == :error
    end

    test "rejects a preview token" do
      principal = TestFixtures.principal(1)
      {token, _session} = insert_session(principal, :preview)

      assert Sessions.control(token) == :error
    end
  end

  describe "preview/2" do
    test "accepts a preview for the right host with a live parent" do
      principal = TestFixtures.principal(1)
      parent = start_control!(principal)
      host = hostname("preview-host")

      {token, session} =
        insert_session(principal, :preview, hostname: host, parent_digest: parent.digest)

      assert {:ok,
              %Authentication{
                actor: %Actor{principal_id: id},
                proof: {:preview, digest, parent_digest, ^host, expires_at}
              }} = Sessions.preview(host, token)

      assert id == principal.id
      assert digest == session.id_digest
      assert parent_digest == parent.digest
      assert expires_at == session.expires_at
    end

    test "rejects a preview for another hostname" do
      principal = TestFixtures.principal(1)
      host = hostname("preview-host")
      {token, _session} = insert_session(principal, :preview, hostname: host)

      assert Sessions.preview(hostname("other-host"), token) == :error
    end

    test "rejects an unknown preview token" do
      assert Sessions.preview(hostname("preview-host"), "nope") == :error
    end

    test "rejects a control token" do
      principal = TestFixtures.principal(1)
      %{token: token} = start_control!(principal)

      assert Sessions.preview(hostname("preview-host"), token) == :error
    end

    test "rejects a preview whose parent is expired" do
      principal = TestFixtures.principal(1)
      parent = start_control!(principal)
      host = hostname("preview-host")

      {token, _session} =
        insert_session(principal, :preview, hostname: host, parent_digest: parent.digest)

      Repo.get!(Session, parent.digest) |> expire()

      assert Sessions.preview(host, token) == :error
    end

    test "rejects a preview whose parent belongs to another principal" do
      principal = TestFixtures.principal(1)
      other = TestFixtures.principal(2)
      host = hostname("preview-host")

      {token, session} =
        insert_session(principal, :preview,
          hostname: host,
          parent_digest: start_control!(other).digest
        )

      assert Sessions.preview(host, token) == :error
      assert session.principal_id == principal.id
    end

    test "rejects a preview whose parent login was logged out" do
      principal = TestFixtures.principal(1)
      parent = start_control!(principal)
      host = hostname("preview-host")

      {token, _session} =
        insert_session(principal, :preview, hostname: host, parent_digest: parent.digest)

      assert Sessions.logout(parent.token) == :ok
      assert Sessions.preview(host, token) == :error
    end

    test "rejects a preview whose principal is disabled" do
      principal = TestFixtures.principal(1)
      parent = start_control!(principal)
      host = hostname("preview-host")

      {token, _session} =
        insert_session(principal, :preview, hostname: host, parent_digest: parent.digest)

      disable(principal)

      assert Sessions.preview(host, token) == :error
    end
  end

  describe "logout/1" do
    test "deletes the control session, its previews, and its handoffs" do
      principal = TestFixtures.principal(1)
      parent = start_control!(principal)
      host = hostname("preview-host")

      {preview_token, preview} =
        insert_session(principal, :preview, hostname: host, parent_digest: parent.digest)

      insert_handoff(host, parent.digest)

      assert Sessions.logout(parent.token) == :ok

      assert Repo.get(Session, parent.digest) == nil
      assert Repo.get(Session, preview.id_digest) == nil
      assert Repo.all(PreviewHandoff) == []

      assert Sessions.control(parent.token) == :error
      assert Sessions.preview(host, preview_token) == :error
    end

    test "a second logout fails" do
      principal = TestFixtures.principal(1)
      parent = start_control!(principal)

      assert Sessions.logout(parent.token) == :ok
      assert Sessions.logout(parent.token) == {:error, :unauthenticated}
    end

    test "a preview token cannot log out" do
      principal = TestFixtures.principal(1)
      parent = start_control!(principal)
      host = hostname("preview-host")

      {token, _session} =
        insert_session(principal, :preview, hostname: host, parent_digest: parent.digest)

      assert Sessions.logout(token) == {:error, :unauthenticated}
      assert Repo.get(Session, parent.digest) != nil
    end

    test "an expired control proof cannot log out" do
      principal = TestFixtures.principal(1)
      {token, session} = insert_session(principal, :control)
      expire(session)

      assert Sessions.logout(token) == {:error, :unauthenticated}
      assert Repo.get(Session, session.id_digest) != nil
    end
  end

  describe "require_control/2" do
    test "accepts the matching live proof and rejects every other proof variant" do
      principal = TestFixtures.principal(1)
      other = TestFixtures.principal(2)
      parent = start_control!(principal)
      {:ok, authentication} = Sessions.control(parent.token)

      assert Sessions.require_control(Repo, authentication) == :ok

      assert Sessions.require_control(Repo, %Authentication{
               authentication
               | actor: %Actor{principal_id: other.id}
             }) ==
               {:error, :unauthenticated}

      proofs = [
        AuthenticationProof.preview(digest(), parent.digest, hostname("preview-host"), future()),
        AuthenticationProof.credential(TestFixtures.id(Biot.Protocol.CredentialId, 1), future()),
        AuthenticationProof.ssh_key(TestFixtures.id(SshKeyId, 1))
      ]

      for proof <- proofs do
        assert Sessions.require_control(Repo, %Authentication{
                 actor: authentication.actor,
                 proof: proof
               }) ==
                 {:error, :unauthenticated}
      end
    end

    test "rejects a fabricated digest and an expired stored proof" do
      principal = TestFixtures.principal(1)
      parent = start_control!(principal)
      {:ok, authentication} = Sessions.control(parent.token)

      fabricated = %Authentication{
        actor: authentication.actor,
        proof: AuthenticationProof.control(digest(), future())
      }

      assert Sessions.require_control(Repo, fabricated) == {:error, :unauthenticated}

      Repo.get!(Session, parent.digest) |> expire()
      assert Sessions.require_control(Repo, authentication) == {:error, :unauthenticated}
    end
  end

  describe "live_control/2" do
    test "returns the live control row and nil for previews, expiry, and disablement" do
      principal = TestFixtures.principal(1)
      parent = start_control!(principal)
      assert %Session{} = Sessions.live_control(Repo, parent.digest)

      {_token, preview} = insert_session(principal, :preview)
      assert Sessions.live_control(Repo, preview.id_digest) == nil

      expired = start_control!(principal)
      Repo.get!(Session, expired.digest) |> expire()
      assert Sessions.live_control(Repo, expired.digest) == nil

      disabled = start_control!(principal)
      disable(principal)
      assert Sessions.live_control(Repo, disabled.digest) == nil
    end
  end

  describe "session shape" do
    test "a control row cannot carry a hostname or parent and a preview row needs both" do
      principal = TestFixtures.principal(1)
      parent = start_control!(principal)

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%Session{
          id_digest: digest(),
          principal_id: principal.id,
          scope: :control,
          hostname: hostname("preview-host"),
          expires_at: future()
        })
      end

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%Session{
          id_digest: digest(),
          principal_id: principal.id,
          scope: :preview,
          hostname: nil,
          control_session_digest: parent.digest,
          expires_at: future()
        })
      end

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%Session{
          id_digest: digest(),
          principal_id: principal.id,
          scope: :preview,
          hostname: hostname("preview-host"),
          control_session_digest: nil,
          expires_at: future()
        })
      end

      assert Repo.get(Session, parent.digest) != nil
    end
  end

  defp insert_handoff(host, parent_digest) do
    {_code, code_digest} = Tokens.mint()
    {_challenge, challenge_digest} = Tokens.mint()

    Repo.insert!(%PreviewHandoff{
      code_digest: code_digest,
      hostname: host,
      control_session_digest: parent_digest,
      challenge_digest: challenge_digest,
      return_path: same_origin(),
      expires_at: future()
    })
  end

  defp digest do
    {_token, digest} = Tokens.mint()
    digest
  end

  defp disable(principal) do
    Repo.update_all(from(p in Principal, where: p.id == ^principal.id), set: [status: :disabled])
  end
end
