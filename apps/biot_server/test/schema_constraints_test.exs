defmodule Biot.Server.SchemaConstraintsTest do
  use Biot.Server.DataCase, async: false

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.Digest
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.NodeId
  alias Biot.Protocol.RepositorySource
  alias Biot.Server.Repo
  alias Biot.Server.Schema.Biot, as: BiotSchema
  alias Biot.Server.Schema.Environment
  alias Biot.Server.Schema.Node, as: NodeSchema
  alias Biot.Server.Schema.Operation
  alias Biot.Server.Schema.Principal, as: PrincipalSchema
  alias Biot.Server.Schema.Publication
  alias Biot.Server.Schema.ShellGrant
  alias Biot.Server.Schema.ViewGrant
  alias Biot.Server.TestFixtures
  alias Ecto.Adapters.SQL.Sandbox

  test "live Biot names are unique per owner while destroyed names can be reused" do
    owner = TestFixtures.principal(1)
    node = TestFixtures.node(1)
    TestFixtures.biot(owner, node, 1, name: "shared-name")

    assert_raise Ecto.ConstraintError, fn ->
      TestFixtures.biot(owner, node, 2, name: "shared-name")
    end

    other_owner = TestFixtures.principal(2)

    TestFixtures.biot(other_owner, node, 3,
      name: "reusable-name",
      desired_state: :destroyed
    )

    assert {%BiotSchema{desired_state: :running}, %Environment{}} =
             TestFixtures.biot(other_owner, node, 4, name: "reusable-name")
  end

  test "publication port and hostname uniqueness are enforced" do
    owner = TestFixtures.principal(1)
    node = TestFixtures.node(1)
    {biot, _environment} = TestFixtures.biot(owner, node, 1)

    first = %Publication{
      biot_id: biot.id,
      port: TestFixtures.port(3000),
      hostname: TestFixtures.hostname(1)
    }

    Repo.insert!(first)

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert!(%Publication{
        biot_id: biot.id,
        port: first.port,
        hostname: TestFixtures.hostname(2)
      })
    end

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert!(%Publication{
        biot_id: biot.id,
        port: TestFixtures.port(3001),
        hostname: first.hostname
      })
    end
  end

  test "shell and view grant uniqueness are enforced" do
    owner = TestFixtures.principal(1)
    grantee = TestFixtures.principal(2)
    node = TestFixtures.node(1)
    {biot, _environment} = TestFixtures.biot(owner, node, 1)

    publication =
      Repo.insert!(%Publication{
        biot_id: biot.id,
        port: TestFixtures.port(3000),
        hostname: TestFixtures.hostname(1)
      })

    shell_grant = %ShellGrant{biot_id: biot.id, principal_id: grantee.id}
    Repo.insert!(shell_grant)
    assert_raise Ecto.ConstraintError, fn -> Repo.insert!(shell_grant) end

    view_grant = %ViewGrant{
      biot_id: biot.id,
      port: publication.port,
      principal_id: grantee.id
    }

    Repo.insert!(view_grant)
    assert_raise Ecto.ConstraintError, fn -> Repo.insert!(view_grant) end

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert!(%ViewGrant{
        biot_id: biot.id,
        port: TestFixtures.port(3001),
        principal_id: grantee.id
      })
    end
  end

  test "operation revisions and environment ownership are unique" do
    owner = TestFixtures.principal(1)
    node = TestFixtures.node(1)
    {biot, environment} = TestFixtures.biot(owner, node, 1)

    operation = %Operation{
      id: TestFixtures.operation_id(1),
      actor_id: owner.id,
      biot_id: biot.id,
      kind: :create,
      target_revision: 1,
      outcome: :pending,
      failure: nil
    }

    Repo.insert!(operation)

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert!(%{operation | id: TestFixtures.operation_id(2)})
    end

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert!(%Environment{
        id: environment.id,
        biot_id: biot.id,
        selection: TestFixtures.selection(),
        resolution: :unresolved
      })
    end
  end

  test "deleting a publication cascades to its view grants" do
    owner = TestFixtures.principal(1)
    grantee = TestFixtures.principal(2)
    node = TestFixtures.node(1)
    {biot, _environment} = TestFixtures.biot(owner, node, 1)

    publication =
      Repo.insert!(%Publication{
        biot_id: biot.id,
        port: TestFixtures.port(3000),
        hostname: TestFixtures.hostname(1)
      })

    Repo.insert!(%ViewGrant{
      biot_id: biot.id,
      port: publication.port,
      principal_id: grantee.id
    })

    Repo.delete!(publication)

    assert Repo.get_by(ViewGrant,
             biot_id: biot.id,
             port: publication.port,
             principal_id: grantee.id
           ) == nil
  end

  test "operation outcome and failure must agree" do
    owner = TestFixtures.principal(1)
    node = TestFixtures.node(1)
    {biot, _environment} = TestFixtures.biot(owner, node, 1)

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert!(%Operation{
        id: TestFixtures.operation_id(1),
        actor_id: owner.id,
        biot_id: biot.id,
        kind: :start,
        target_revision: 1,
        outcome: :failed,
        failure: nil
      })
    end

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert!(%Operation{
        id: TestFixtures.operation_id(2),
        actor_id: owner.id,
        biot_id: biot.id,
        kind: :start,
        target_revision: 2,
        outcome: :succeeded,
        failure: TestFixtures.failure()
      })
    end
  end

  test "foreign keys reject a Biot assigned to an unknown node" do
    owner = TestFixtures.principal(1)

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert!(%BiotSchema{
        id: TestFixtures.id(BiotId, 1),
        name: TestFixtures.biot_name("unknown-node"),
        owner_id: owner.id,
        node_id: TestFixtures.id(NodeId, 999),
        repository: repository(),
        creation_fingerprint: Digest.compute(:creation_request_v1, "unknown"),
        desired_revision: 1,
        desired_state: :running,
        desired_environment_id: TestFixtures.id(EnvironmentId, 1),
        access_revision: 1
      })
    end
  end

  test "the deferred environment owner key is checked at transaction commit" do
    Sandbox.unboxed_run(Repo, fn ->
      owner = TestFixtures.principal(900_001)
      node = TestFixtures.node(900_001)

      try do
        {first_biot, first_environment} = TestFixtures.biot(owner, node, 900_001)

        ExUnit.CaptureLog.capture_log(fn ->
          assert_raise Exqlite.Error, ~r/FOREIGN KEY constraint failed/, fn ->
            Repo.transaction(fn ->
              Repo.insert!(%BiotSchema{
                id: TestFixtures.id(BiotId, 902_002),
                name: TestFixtures.biot_name("cross-biot-environment"),
                owner_id: owner.id,
                node_id: node.id,
                repository: repository(),
                creation_fingerprint: Digest.compute(:creation_request_v1, "cross-biot"),
                desired_revision: 1,
                desired_state: :running,
                desired_environment_id: first_environment.id,
                access_revision: 1
              })
            end)
          end
        end)

        assert Repo.get!(BiotSchema, first_biot.id).desired_environment_id ==
                 first_environment.id
      after
        Repo.delete_all(BiotSchema)
        Repo.delete_all(NodeSchema)
        Repo.delete_all(PrincipalSchema)
      end
    end)
  end

  defp repository do
    {:ok, repository} =
      RepositorySource.parse("https://github.com/example/project.git")

    repository
  end
end
