defmodule Biot.Server.PrincipalsReloadTest do
  use Biot.Server.DataCase, async: false

  import Ecto.Query

  alias Biot.Protocol.{
    AuthorizationValue,
    BiotId,
    OperationId,
    Port,
    PrincipalId,
    PrivateDiagnosticId,
    RepositorySource,
    SameOriginPath,
    SecretName,
    SecretValue
  }

  alias Biot.Server.{
    Access,
    Biots,
    Credentials,
    Diagnostics,
    FetchCredentials,
    NodeWake,
    Operations,
    Principals,
    Publications,
    Repo,
    RuntimeLogs,
    Secrets,
    Sessions,
    SshKeys
  }

  alias Biot.Server.Biots.SelectEnvironment
  alias Biot.Server.Queries.Biots, as: QueriesBiots
  alias Biot.Server.Queries.Deployment
  alias Biot.Server.Queries.Nodes, as: QueriesNodes
  alias Biot.Server.Schema

  alias Biot.Server.Schema.{
    Credential,
    Operation,
    PreviewHandoff,
    Publication,
    Session,
    ShellGrant,
    SshKey,
    ViewGrant
  }

  alias Biot.Server.TestFixtures
  alias Biot.Server.Tokens

  @issuer "https://issuer.example"

  @ed25519 "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINzyzz1M9L5KLhn5k5Lh3Peq0ipDgKB4DPAJ0A7UqS06"

  setup do
    Application.delete_env(:biot_server, :disabled_principals_file)

    on_exit(fn ->
      Application.delete_env(:biot_server, :disabled_principals_file)
    end)

    :ok
  end

  defp identity(principal), do: %{"issuer" => principal.issuer, "subject" => principal.subject}

  defp configure(identities),
    do: TestFixtures.put_disabled_principals(identities)

  defp drain_wakes(acc \\ []) do
    receive do
      {:biot_spec_changed, biot_id} -> drain_wakes([biot_id | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp subscribe(node_id), do: assert(NodeWake.subscribe(node_id) == :ok)

  defp control(principal) do
    {:ok, token} = Sessions.start_control(principal.id)
    {:ok, authentication} = Sessions.control(token)
    %{authentication: authentication, token: token, digest: Tokens.digest(token)}
  end

  defp seed do
    owner = TestFixtures.principal(1, issuer: @issuer, subject: "owner")
    collaborator = TestFixtures.principal(2, issuer: @issuer, subject: "collaborator")
    node = TestFixtures.node(1)
    {biot1, _environment1} = TestFixtures.biot(owner, node, 1)
    {biot2, _environment2} = TestFixtures.biot(collaborator, node, 2)

    Repo.insert!(%ShellGrant{biot_id: biot1.id, principal_id: collaborator.id})

    publication =
      Repo.insert!(%Publication{
        biot_id: biot1.id,
        port: TestFixtures.port(3_000),
        hostname: TestFixtures.hostname(1),
        state: :active
      })

    Repo.insert!(%ViewGrant{
      biot_id: biot1.id,
      port: publication.port,
      principal_id: collaborator.id
    })

    %{
      owner: owner,
      collaborator: collaborator,
      node: node,
      biot1: biot1,
      biot2: biot2,
      publication: publication
    }
  end

  defp revision(biot), do: Repo.get!(Schema.Biot, biot.id).access_revision

  describe "reload/0 disables configured principals" do
    test "it deletes every proof, keeps ownership and grants, and bumps each affected biot once" do
      context = seed()
      subscribe(context.node.id)

      %{authentication: owner_control, digest: owner_digest} = control(context.owner)

      {:ok, %Credentials.Created{credential: credential}} =
        Credentials.create(owner_control, "cli", future())

      {:ok, ssh_key} = SshKeys.add(TestFixtures.actor(context.owner), @ed25519, "laptop")

      {_preview_token, preview_digest} = insert_preview(context.owner, owner_digest)
      {_code, code_digest} = insert_handoff(context.publication.hostname, owner_digest)

      operation =
        Repo.insert!(%Operation{
          id: TestFixtures.operation_id(1),
          actor_id: context.owner.id,
          biot_id: context.biot1.id,
          kind: :start,
          target_revision: 1,
          outcome: :pending,
          failure: nil
        })

      configure([identity(context.owner), identity(context.collaborator)])

      assert Principals.reload() == :ok

      assert Repo.get!(Schema.Principal, context.owner.id).status == :disabled
      assert Repo.get!(Schema.Principal, context.collaborator.id).status == :disabled

      assert Repo.all(Session) == []
      assert Repo.get(Session, preview_digest) == nil
      assert Repo.get(PreviewHandoff, code_digest) == nil
      assert Repo.get(Credential, credential.id) == nil
      assert Repo.get(SshKey, ssh_key.id) == nil

      assert Repo.get!(Schema.Biot, context.biot1.id).owner_id == context.owner.id
      assert Repo.get!(Schema.Biot, context.biot2.id).owner_id == context.collaborator.id

      assert Repo.get_by(ShellGrant,
               biot_id: context.biot1.id,
               principal_id: context.collaborator.id
             )

      assert Repo.get_by(ViewGrant,
               biot_id: context.biot1.id,
               principal_id: context.collaborator.id
             )

      assert Repo.get(Operation, operation.id) != nil

      assert revision(context.biot1) == 2
      assert revision(context.biot2) == 2

      wakes = drain_wakes()

      assert Enum.sort_by(wakes, &BiotId.to_string/1) ==
               Enum.sort_by([context.biot1.id, context.biot2.id], &BiotId.to_string/1)
    end

    test "a repeated reload changes nothing and wakes nothing" do
      context = seed()
      subscribe(context.node.id)
      configure([identity(context.owner)])

      assert Principals.reload() == :ok
      assert revision(context.biot1) == 2
      _ = drain_wakes()

      assert Principals.reload() == :ok
      assert revision(context.biot1) == 2
      assert revision(context.biot2) == 1
      assert drain_wakes() == []
    end

    test "re-enabling restores no revoked proofs and does not change revisions" do
      context = seed()
      %{digest: control_digest} = control(context.owner)
      {_token, preview_digest} = insert_preview(context.owner, control_digest)
      configure([identity(context.owner)])

      assert Principals.reload() == :ok
      assert Repo.get(Session, control_digest) == nil
      assert Repo.get(Session, preview_digest) == nil
      assert revision(context.biot1) == 2

      configure([])
      assert Principals.reload() == :ok

      assert Repo.get!(Schema.Principal, context.owner.id).status == :enabled
      assert Repo.get(Session, control_digest) == nil
      assert Repo.get(Session, preview_digest) == nil
      assert revision(context.biot1) == 2
    end

    test "a configured identity unknown before first login is stored disabled" do
      seed()

      configure([%{"issuer" => @issuer, "subject" => "not-seen-yet"}])
      assert Principals.reload() == :ok

      principal =
        Repo.get_by!(Schema.Principal, issuer: @issuer, subject: "not-seen-yet")

      assert principal.status == :disabled

      assert {:ok, identified} =
               Principals.identify(@issuer, "not-seen-yet", %{email: nil, name: nil})

      assert identified.id == principal.id
      assert identified.status == :disabled
      assert Sessions.start_control(principal.id) == {:error, :unauthenticated}
    end

    test "a repeated identity disables once and inserts one row" do
      context = seed()
      duplicate = [identity(context.owner), identity(context.owner)]

      configure(duplicate)
      assert Principals.reload() == :ok

      assert Repo.aggregate(
               from(p in Schema.Principal,
                 where: p.issuer == ^@issuer and p.subject == "owner"
               ),
               :count
             ) == 1

      assert revision(context.biot1) == 2

      configure(duplicate)
      assert Principals.reload() == :ok
      assert revision(context.biot1) == 2
    end
  end

  describe "reload/0 with invalid configuration" do
    test "a non-list value changes nothing" do
      context = seed()
      assert Principals.reload() == :ok
      assert revision(context.biot1) == 1

      configure(%{"issuer" => @issuer})
      assert {:error, :not_a_list} = Principals.reload()

      assert Repo.get!(Schema.Principal, context.owner.id).status == :enabled
      assert revision(context.biot1) == 1
    end

    test "an invalid file changes nothing" do
      context = seed()

      path =
        BiotTest.Temp.directory("biot-reload") <> ".json"

      File.write!(path, "{not json")
      Application.put_env(:biot_server, :disabled_principals_file, path)

      assert {:error, {:invalid_json, _message}} = Principals.reload()

      assert Repo.get!(Schema.Principal, context.owner.id).status == :enabled
      assert revision(context.biot1) == 1
    end
  end

  describe "a disabled principal at every application boundary" do
    test "each boundary returns unauthenticated" do
      principal = TestFixtures.principal(1)

      Repo.update_all(from(p in Schema.Principal, where: p.id == ^principal.id),
        set: [status: :disabled]
      )

      actor = TestFixtures.actor(principal)

      calls = [
        {"Deployment.get", fn -> Deployment.get(actor) end},
        {"Nodes.list", fn -> QueriesNodes.list(actor) end},
        {"Operations.get", fn -> Operations.get(actor, uniq(OperationId)) end},
        {"Diagnostics.get", fn -> Diagnostics.get(actor, uniq(PrivateDiagnosticId)) end},
        {"Principals.resolve_email",
         fn -> Principals.resolve_email(actor, "nobody@example.test") end},
        {"Access.get_grants", fn -> Access.get_grants(actor, uniq(BiotId)) end},
        {"Access.fetch_readable", fn -> Access.fetch_readable(actor, uniq(BiotId)) end},
        {"Access.grant_shell",
         fn -> Access.grant_shell(actor, uniq(BiotId), uniq(PrincipalId)) end},
        {"Access.revoke_shell",
         fn -> Access.revoke_shell(actor, uniq(BiotId), uniq(PrincipalId)) end},
        {"Access.grant_view",
         fn -> Access.grant_view(actor, uniq(BiotId), port(80), uniq(PrincipalId)) end},
        {"Access.revoke_view",
         fn -> Access.revoke_view(actor, uniq(BiotId), port(80), uniq(PrincipalId)) end},
        {"Queries.Biots.get", fn -> QueriesBiots.get(actor, uniq(BiotId)) end},
        {"Queries.Biots.list", fn -> QueriesBiots.list(actor, %{after: nil, limit: 10}) end},
        {"Biots.create",
         fn -> Biots.create(actor, uniq(BiotId), TestFixtures.create_command()) end},
        {"Biots.start", fn -> Biots.start(actor, uniq(BiotId), 1) end},
        {"Biots.stop", fn -> Biots.stop(actor, uniq(BiotId), 1) end},
        {"Biots.update_environment",
         fn ->
           Biots.update_environment(
             actor,
             uniq(BiotId),
             %SelectEnvironment{selection: TestFixtures.selection()},
             1
           )
         end},
        {"Biots.destroy", fn -> Biots.destroy(actor, uniq(BiotId)) end},
        {"Publications.publish", fn -> Publications.publish(actor, uniq(BiotId), port(80)) end},
        {"Publications.unpublish",
         fn -> Publications.unpublish(actor, uniq(BiotId), port(80)) end},
        {"Publications.discover", fn -> Publications.discover(actor, uniq(BiotId)) end},
        {"Secrets.list", fn -> Secrets.list(actor, uniq(BiotId)) end},
        {"Secrets.deliver",
         fn -> Secrets.deliver(actor, uniq(BiotId), secret_name(), secret_value()) end},
        {"Secrets.remove", fn -> Secrets.remove(actor, uniq(BiotId), secret_name()) end},
        {"FetchCredentials.deliver",
         fn -> FetchCredentials.deliver(actor, uniq(BiotId), source(), authorization()) end},
        {"FetchCredentials.remove",
         fn -> FetchCredentials.remove(actor, uniq(BiotId), source()) end},
        {"RuntimeLogs.get", fn -> RuntimeLogs.get(actor, uniq(BiotId), 1_024) end}
      ]

      for {name, call} <- calls do
        assert call.() == {:error, :unauthenticated}, "#{name} allowed a disabled principal"
      end
    end
  end

  defp insert_preview(principal, parent_digest) do
    {token, digest} = Tokens.mint()

    Repo.insert!(%Session{
      id_digest: digest,
      principal_id: principal.id,
      scope: :preview,
      hostname: TestFixtures.hostname(9),
      control_session_digest: parent_digest,
      expires_at: future()
    })

    {token, digest}
  end

  defp insert_handoff(hostname, parent_digest) do
    {code, code_digest} = Tokens.mint()
    {_challenge, challenge_digest} = Tokens.mint()
    {:ok, return_path} = SameOriginPath.parse("/preview/start")

    Repo.insert!(%PreviewHandoff{
      code_digest: code_digest,
      hostname: hostname,
      control_session_digest: parent_digest,
      challenge_digest: challenge_digest,
      return_path: return_path,
      expires_at: future()
    })

    {code, code_digest}
  end

  defp future, do: DateTime.add(DateTime.utc_now(), 3_600, :second)

  defp uniq(module) do
    {:ok, value} = module.parse(Ecto.UUID.generate())
    value
  end

  defp port(number) do
    {:ok, value} = Port.parse(number)
    value
  end

  defp secret_name do
    {:ok, value} = SecretName.parse("PIECE_ONE_CHECK")
    value
  end

  defp secret_value do
    {:ok, value} = SecretValue.parse("check", 1)
    value
  end

  defp source do
    {:ok, value} = RepositorySource.parse("https://github.com/example/check.git")
    value
  end

  defp authorization do
    {:ok, value} = AuthorizationValue.parse("Bearer check", 1)
    value
  end
end
