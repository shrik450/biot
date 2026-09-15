defmodule Biot.Server.PreviewHandoffIntegrationTest do
  use Biot.Server.DataCase, async: false

  import Ecto.Query

  alias Biot.Protocol.{CredentialId, Hostname, SameOriginPath, SshKeyId}
  alias Biot.Server.Actor
  alias Biot.Server.Authentication
  alias Biot.Server.AuthenticationProof
  alias Biot.Server.PreviewHandoff
  alias Biot.Server.PreviewHandoff.Finished
  alias Biot.Server.Publications
  alias Biot.Server.Repo
  alias Biot.Server.Schema.PreviewHandoff, as: HandoffRow
  alias Biot.Server.Schema.{Principal, Publication, Session, ViewGrant}
  alias Biot.Server.Sessions
  alias Biot.Server.TestFixtures
  alias Biot.Server.Tokens

  setup do
    owner = TestFixtures.principal(1)
    collaborator = TestFixtures.principal(2)
    stranger = TestFixtures.principal(3)
    node = TestFixtures.node(1)
    {biot, _environment} = TestFixtures.biot(owner, node, 1)

    %{
      owner: owner,
      collaborator: collaborator,
      stranger: stranger,
      biot: biot,
      port: TestFixtures.port(3_000),
      hostname: TestFixtures.hostname(1)
    }
  end

  defp control(principal) do
    {:ok, token} = Sessions.start_control(principal.id)
    {:ok, authentication} = Sessions.control(token)
    %{authentication: authentication, token: token}
  end

  defp challenge do
    clear = "challenge-#{System.unique_integer([:positive])}"
    {clear, Tokens.digest(clear)}
  end

  defp same_origin do
    {:ok, path} = SameOriginPath.parse("/preview/start?step=1")
    path
  end

  defp digest do
    {_token, digest} = Tokens.mint()
    digest
  end

  defp hostname(value) do
    {:ok, hostname} = Hostname.parse(value)
    hostname
  end

  defp disable(principal) do
    Repo.update_all(from(p in Principal, where: p.id == ^principal.id), set: [status: :disabled])
  end

  defp publish(context, state \\ :active) do
    Repo.insert!(%Publication{
      biot_id: context.biot.id,
      port: context.port,
      hostname: context.hostname,
      state: state
    })
  end

  defp grant_view(context, principal) do
    Repo.insert!(%ViewGrant{
      biot_id: context.biot.id,
      port: context.port,
      principal_id: principal.id
    })
  end

  describe "begin/4" do
    test "requires a live control proof of every other variant", context do
      publish(context)
      %{authentication: owner_control} = control(context.owner)

      assert PreviewHandoff.begin(nil, context.hostname, digest(), same_origin()) ==
               {:error, :unauthenticated}

      for proof <- [
            AuthenticationProof.credential(TestFixtures.id(CredentialId, 1), future()),
            AuthenticationProof.preview(digest(), digest(), context.hostname, future()),
            AuthenticationProof.ssh_key(TestFixtures.id(SshKeyId, 1)),
            AuthenticationProof.control(digest(), future())
          ] do
        assert PreviewHandoff.begin(
                 %Authentication{actor: owner_control.actor, proof: proof},
                 context.hostname,
                 digest(),
                 same_origin()
               ) == {:error, :unauthenticated}
      end
    end

    test "requires an active publication", context do
      %{authentication: owner_control} = control(context.owner)

      assert PreviewHandoff.begin(owner_control, context.hostname, digest(), same_origin()) ==
               {:error, :not_found}

      publish(context, :inactive)

      assert PreviewHandoff.begin(owner_control, context.hostname, digest(), same_origin()) ==
               {:error, :not_found}
    end

    test "requires view authority", context do
      publish(context)

      assert PreviewHandoff.begin(
               control(context.stranger).authentication,
               context.hostname,
               digest(),
               same_origin()
             ) == {:error, :forbidden}

      grant_view(context, context.stranger)

      assert {:ok, _code} =
               PreviewHandoff.begin(
                 control(context.stranger).authentication,
                 context.hostname,
                 digest(),
                 same_origin()
               )

      assert {:ok, code} =
               PreviewHandoff.begin(
                 control(context.owner).authentication,
                 context.hostname,
                 digest(),
                 same_origin()
               )

      assert is_binary(code)
    end

    test "rejects a disabled principal", context do
      publish(context)
      %{authentication: owner_control} = control(context.owner)
      disable(context.owner)

      assert PreviewHandoff.begin(owner_control, context.hostname, digest(), same_origin()) ==
               {:error, :unauthenticated}

      assert Repo.all(HandoffRow) == []
    end

    test "stores only the code digest and the bound fields", context do
      publish(context)
      %{authentication: owner_control, token: control_token} = control(context.owner)
      challenge_digest = digest()

      assert {:ok, code} =
               PreviewHandoff.begin(
                 owner_control,
                 context.hostname,
                 challenge_digest,
                 same_origin()
               )

      assert [handoff] = Repo.all(HandoffRow)
      assert handoff.code_digest == Tokens.digest(code)
      refute handoff.code_digest == code
      assert handoff.hostname == context.hostname
      assert handoff.challenge_digest == challenge_digest
      assert handoff.return_path == same_origin()
      assert handoff.control_session_digest == Tokens.digest(control_token)
      assert DateTime.compare(handoff.expires_at, DateTime.utc_now()) == :gt
    end

    test "a control session that was logged out cannot begin", context do
      publish(context)
      %{authentication: owner_control, token: token} = control(context.owner)
      assert Sessions.logout(token) == :ok

      assert PreviewHandoff.begin(owner_control, context.hostname, digest(), same_origin()) ==
               {:error, :unauthenticated}
    end
  end

  describe "finish/3" do
    test "creates a preview session that expires with its parent and can be looked up", context do
      publish(context)
      %{authentication: owner_control, token: control_token} = control(context.owner)
      {clear_challenge, challenge_digest} = challenge()

      assert {:ok, code} =
               PreviewHandoff.begin(
                 owner_control,
                 context.hostname,
                 challenge_digest,
                 same_origin()
               )

      assert {:ok, %Finished{token: preview_token, return_path: return_path}} =
               PreviewHandoff.finish(context.hostname, code, clear_challenge)

      assert SameOriginPath.to_string(return_path) == "/preview/start?step=1"

      parent = Repo.get!(Session, Tokens.digest(control_token))
      preview = Repo.get!(Session, Tokens.digest(preview_token))

      assert preview.scope == :preview
      assert preview.principal_id == context.owner.id
      assert preview.hostname == context.hostname
      assert preview.control_session_digest == parent.id_digest
      assert preview.expires_at == parent.expires_at

      assert {:ok,
              %Authentication{actor: %Actor{principal_id: id}, proof: {:preview, _, _, host, _}}} =
               Sessions.preview(context.hostname, preview_token)

      assert id == context.owner.id
      assert host == context.hostname
      assert Repo.all(HandoffRow) == []
    end

    test "a code works once", context do
      publish(context)
      %{authentication: owner_control} = control(context.owner)
      {clear_challenge, challenge_digest} = challenge()

      {:ok, code} =
        PreviewHandoff.begin(owner_control, context.hostname, challenge_digest, same_origin())

      assert {:ok, %Finished{}} = PreviewHandoff.finish(context.hostname, code, clear_challenge)

      assert PreviewHandoff.finish(context.hostname, code, clear_challenge) ==
               {:error, :unauthenticated}
    end

    test "a code is bound to one host and one challenge", context do
      publish(context)

      other_host = hostname("other-host")

      Repo.insert!(%Publication{
        biot_id: context.biot.id,
        port: TestFixtures.port(3_001),
        hostname: other_host,
        state: :active
      })

      %{authentication: owner_control} = control(context.owner)
      {clear_challenge, challenge_digest} = challenge()

      {:ok, code} =
        PreviewHandoff.begin(owner_control, context.hostname, challenge_digest, same_origin())

      # The other host is an active publication the same principal may view, so
      # only the code's own hostname check can reject this redemption.
      assert PreviewHandoff.finish(other_host, code, clear_challenge) ==
               {:error, :unauthenticated}

      assert PreviewHandoff.finish(context.hostname, code, "wrong-challenge") ==
               {:error, :unauthenticated}

      assert PreviewHandoff.finish(context.hostname, "unknown-code", clear_challenge) ==
               {:error, :unauthenticated}

      assert Repo.get(HandoffRow, Tokens.digest(code)) != nil
    end

    test "an expired handoff is rejected", context do
      publish(context)
      %{authentication: owner_control} = control(context.owner)
      {clear_challenge, challenge_digest} = challenge()

      {:ok, code} =
        PreviewHandoff.begin(owner_control, context.hostname, challenge_digest, same_origin())

      Repo.get!(HandoffRow, Tokens.digest(code))
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
      |> Repo.update!()

      assert PreviewHandoff.finish(context.hostname, code, clear_challenge) ==
               {:error, :unauthenticated}
    end

    test "never works after the parent logs out", context do
      publish(context)
      %{authentication: owner_control, token: control_token} = control(context.owner)
      {clear_challenge, challenge_digest} = challenge()

      {:ok, code} =
        PreviewHandoff.begin(owner_control, context.hostname, challenge_digest, same_origin())

      assert Sessions.logout(control_token) == :ok

      assert PreviewHandoff.finish(context.hostname, code, clear_challenge) ==
               {:error, :unauthenticated}

      assert Repo.all(HandoffRow) == []
      assert Repo.all(Session) == []
    end

    test "never works after the parent expires", context do
      publish(context)
      %{authentication: owner_control, token: control_token} = control(context.owner)
      {clear_challenge, challenge_digest} = challenge()

      {:ok, code} =
        PreviewHandoff.begin(owner_control, context.hostname, challenge_digest, same_origin())

      Repo.get!(Session, Tokens.digest(control_token))
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
      |> Repo.update!()

      assert PreviewHandoff.finish(context.hostname, code, clear_challenge) ==
               {:error, :unauthenticated}
    end

    test "never works after the view grant is revoked", context do
      publish(context)
      grant_view(context, context.collaborator)
      %{authentication: collaborator_control} = control(context.collaborator)
      {clear_challenge, challenge_digest} = challenge()

      {:ok, code} =
        PreviewHandoff.begin(
          collaborator_control,
          context.hostname,
          challenge_digest,
          same_origin()
        )

      Repo.delete_all(
        from(grant in ViewGrant,
          where:
            grant.biot_id == ^context.biot.id and grant.principal_id == ^context.collaborator.id
        )
      )

      assert PreviewHandoff.finish(context.hostname, code, clear_challenge) ==
               {:error, :unauthenticated}
    end

    test "never works after the publication is deactivated", context do
      publication = publish(context)
      %{authentication: owner_control} = control(context.owner)
      {clear_challenge, challenge_digest} = challenge()

      {:ok, code} =
        PreviewHandoff.begin(owner_control, context.hostname, challenge_digest, same_origin())

      publication
      |> Ecto.Changeset.change(state: :inactive)
      |> Repo.update!()

      assert PreviewHandoff.finish(context.hostname, code, clear_challenge) ==
               {:error, :unauthenticated}

      assert Publications.active_by_hostname(Repo, context.hostname) == nil
    end

    test "never works after the parent principal is disabled", context do
      publish(context)
      %{authentication: owner_control} = control(context.owner)
      {clear_challenge, challenge_digest} = challenge()

      {:ok, code} =
        PreviewHandoff.begin(owner_control, context.hostname, challenge_digest, same_origin())

      disable(context.owner)

      assert PreviewHandoff.finish(context.hostname, code, clear_challenge) ==
               {:error, :unauthenticated}
    end
  end

  describe "active_by_hostname/2" do
    test "returns only the active publication for a hostname", context do
      publish(context)
      assert %Publication{} = Publications.active_by_hostname(Repo, context.hostname)
      assert Publications.active_by_hostname(Repo, hostname("missing-host")) == nil
    end
  end

  defp future, do: DateTime.add(DateTime.utc_now(), 3_600, :second)
end
