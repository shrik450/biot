defmodule Biot.Server.PolicyRecordsTest do
  use Biot.Server.DataCase, async: false

  import Ecto.Query

  alias Biot.Protocol.{BiotId, PrincipalId}
  alias Biot.Server.{Access, Biots, NodeConnections, NodeWake, Publications, Reports}
  alias Biot.Server.Biots.Accepted
  alias Biot.Server.Policy.{Applied, Unchanged}
  alias Biot.Server.Queries
  alias Biot.Server.Queries.AccessView
  alias Biot.Server.Repo
  alias Biot.Server.Schema.Biot, as: BiotRow
  alias Biot.Server.Schema.{Publication, ShellGrant, ViewGrant}
  alias Biot.Server.TestFixtures

  setup do
    owner = TestFixtures.principal(1)
    viewer = TestFixtures.principal(2)
    other_viewer = TestFixtures.principal(3)
    node = TestFixtures.node(1)
    actor = TestFixtures.actor(owner)
    biot_id = TestFixtures.id(BiotId, 9_001)

    assert {:ok, %Accepted{}} =
             Biots.create(
               actor,
               biot_id,
               TestFixtures.create_command(name: "policy-biot", node_id: node.id)
             )

    :ok = NodeWake.subscribe(node.id)
    on_exit(fn -> NodeConnections.delete(node.id) end)

    %{
      owner: owner,
      actor: actor,
      viewer: viewer,
      viewer_actor: TestFixtures.actor(viewer),
      other_viewer: other_viewer,
      other_actor: TestFixtures.actor(other_viewer),
      node: node,
      biot_id: biot_id,
      port: TestFixtures.port(4_000)
    }
  end

  test "publish is stable and visible through discovery and the Biot view", context do
    assert {:ok, %Applied{} = published} =
             Publications.publish(context.actor, context.biot_id, context.port)

    assert_policy(published, context, 1, {:pending, context.node.id})
    assert_no_wake()

    domain = Application.fetch_env!(:biot_server, :publication_domain)
    row = Repo.get_by!(Publication, biot_id: context.biot_id, port: context.port)
    assert row.state == :active
    expected = %{port: context.port, url: "https://#{row.hostname}.#{domain}"}

    assert Publications.discover(context.actor, context.biot_id) == {:ok, [expected]}

    assert {:ok, biot_view} = Queries.Biots.get(context.actor, context.biot_id)
    assert biot_view.publications == [expected]
    assert biot_view.access == %{revision: 1, enforcement: {:pending, context.node.id}}

    assert {:ok, %Unchanged{} = repeated} =
             Publications.publish(context.actor, context.biot_id, context.port)

    assert_policy(repeated, context, 1, {:pending, context.node.id})
    assert_no_wake()
    assert Repo.aggregate(Publication, :count) == 1
  end

  test "each published port receives its own random hostname", context do
    other_port = TestFixtures.port(5_000)

    assert {:ok, %Applied{}} = Publications.publish(context.actor, context.biot_id, context.port)
    assert {:ok, %Applied{}} = Publications.publish(context.actor, context.biot_id, other_port)

    hostnames =
      Repo.all(from(row in Publication, where: row.biot_id == ^context.biot_id))
      |> Enum.map(& &1.hostname)

    assert length(Enum.uniq(hostnames)) == 2
  end

  test "unpublish advances one revision and republish restores no view grants", context do
    assert {:ok, %Applied{}} = Publications.publish(context.actor, context.biot_id, context.port)

    assert {:ok, [%{url: original_url}]} =
             Publications.discover(context.actor, context.biot_id)

    assert {:ok, %Applied{access_revision: 1}} =
             Access.grant_view(context.actor, context.biot_id, context.port, context.viewer.id)

    assert_no_wake()

    assert {:ok, %Applied{} = unpublished} =
             Publications.unpublish(context.actor, context.biot_id, context.port)

    assert_policy(unpublished, context, 2, {:pending, context.node.id})
    assert_one_wake(context.biot_id)
    assert Publications.discover(context.actor, context.biot_id) == {:ok, []}
    assert {:ok, %AccessView{view_grants: []}} = Access.get_grants(context.actor, context.biot_id)

    assert {:ok, %Applied{} = republished} =
             Publications.publish(context.actor, context.biot_id, context.port)

    assert_policy(republished, context, 2, {:pending, context.node.id})
    assert_no_wake()

    assert {:ok, [%{port: port, url: ^original_url}]} =
             Publications.discover(context.actor, context.biot_id)

    assert port == context.port
    assert {:ok, %AccessView{view_grants: []}} = Access.get_grants(context.actor, context.biot_id)
  end

  test "publish, unpublish, and republish keep one row with one hostname", context do
    assert {:ok, %Applied{}} = Publications.publish(context.actor, context.biot_id, context.port)
    first = Repo.get_by!(Publication, biot_id: context.biot_id, port: context.port)
    assert first.state == :active

    assert {:ok, %Applied{}} =
             Publications.unpublish(context.actor, context.biot_id, context.port)

    withdrawn = Repo.get_by!(Publication, biot_id: context.biot_id, port: context.port)
    assert withdrawn.state == :inactive
    assert withdrawn.hostname == first.hostname
    assert Repo.aggregate(Publication, :count) == 1
    assert Publications.discover(context.actor, context.biot_id) == {:ok, []}

    assert {:ok, %Applied{}} = Publications.publish(context.actor, context.biot_id, context.port)

    restored = Repo.get_by!(Publication, biot_id: context.biot_id, port: context.port)
    assert restored.state == :active
    assert restored.hostname == first.hostname
    assert Repo.aggregate(Publication, :count) == 1
  end

  test "unpublish withdraws one revision and repeats are unchanged", context do
    other_port = TestFixtures.port(5_000)
    assert {:ok, %Applied{}} = Publications.publish(context.actor, context.biot_id, context.port)
    assert {:ok, %Applied{}} = Publications.publish(context.actor, context.biot_id, other_port)

    assert {:ok, %Applied{access_revision: 1}} =
             Access.grant_view(context.actor, context.biot_id, context.port, context.viewer.id)

    assert {:ok, %Applied{access_revision: 1}} =
             Access.grant_view(context.actor, context.biot_id, other_port, context.viewer.id)

    assert {:ok, %Applied{access_revision: 2}} =
             Publications.unpublish(context.actor, context.biot_id, context.port)

    assert Repo.all(from(grant in ViewGrant, where: grant.biot_id == ^context.biot_id))
           |> Enum.map(& &1.port) == [other_port]

    assert Repo.get_by!(Publication, biot_id: context.biot_id, port: other_port).state == :active

    assert {:ok, %Unchanged{access_revision: 2}} =
             Publications.unpublish(context.actor, context.biot_id, context.port)

    assert Repo.get!(BiotRow, context.biot_id).access_revision == 2
  end

  test "unpublishing a port that was never published is unchanged", context do
    assert {:ok, %Unchanged{access_revision: 1}} =
             Publications.unpublish(context.actor, context.biot_id, context.port)

    assert Repo.aggregate(Publication, :count) == 0
  end

  test "grant additions do not advance the revision or wake the node", context do
    assert {:ok, %Applied{}} = Publications.publish(context.actor, context.biot_id, context.port)

    assert {:ok, %Applied{} = shell} =
             Access.grant_shell(context.actor, context.biot_id, context.viewer.id)

    assert_policy(shell, context, 1, {:pending, context.node.id})

    assert {:ok, %Applied{} = view} =
             Access.grant_view(context.actor, context.biot_id, context.port, context.viewer.id)

    assert_policy(view, context, 1, {:pending, context.node.id})

    assert {:ok, %Unchanged{} = repeated_shell} =
             Access.grant_shell(context.actor, context.biot_id, context.viewer.id)

    assert_policy(repeated_shell, context, 1, {:pending, context.node.id})

    assert {:ok, %Unchanged{} = repeated_view} =
             Access.grant_view(context.actor, context.biot_id, context.port, context.viewer.id)

    assert_policy(repeated_view, context, 1, {:pending, context.node.id})
    assert Repo.get!(BiotRow, context.biot_id).access_revision == 1
    assert_no_wake()
  end

  test "grant withdrawals each advance one revision and wake once", context do
    assert {:ok, %Applied{}} = Publications.publish(context.actor, context.biot_id, context.port)

    assert {:ok, %Applied{}} =
             Access.grant_shell(context.actor, context.biot_id, context.viewer.id)

    assert {:ok, %Applied{}} =
             Access.grant_view(context.actor, context.biot_id, context.port, context.viewer.id)

    assert_no_wake()

    assert {:ok, %Applied{} = shell_revoked} =
             Access.revoke_shell(context.actor, context.biot_id, context.viewer.id)

    assert_policy(shell_revoked, context, 2, {:pending, context.node.id})
    assert_one_wake(context.biot_id)

    assert {:ok, %Unchanged{} = missing_shell} =
             Access.revoke_shell(context.actor, context.biot_id, context.viewer.id)

    assert_policy(missing_shell, context, 2, {:pending, context.node.id})
    assert_no_wake()

    assert {:ok, %Applied{} = view_revoked} =
             Access.revoke_view(context.actor, context.biot_id, context.port, context.viewer.id)

    assert_policy(view_revoked, context, 3, {:pending, context.node.id})
    assert_one_wake(context.biot_id)

    assert {:ok, %Unchanged{} = missing_view} =
             Access.revoke_view(context.actor, context.biot_id, context.port, context.viewer.id)

    assert_policy(missing_view, context, 3, {:pending, context.node.id})
    assert_no_wake()

    assert Access.get_grants(context.actor, context.biot_id) ==
             {:ok, %AccessView{owner_id: context.owner.id, shell_grants: [], view_grants: []}}
  end

  test "a view grant requires this Biot to publish the port", context do
    assert Access.grant_view(
             context.actor,
             context.biot_id,
             context.port,
             context.viewer.id
           ) == {:error, :not_found}

    other_biot_id = TestFixtures.id(BiotId, 9_002)
    create_biot(context, other_biot_id, "other-policy-biot")
    assert_one_wake(other_biot_id)

    assert {:ok, %Applied{}} = Publications.publish(context.actor, context.biot_id, context.port)

    assert Access.grant_view(context.actor, other_biot_id, context.port, context.viewer.id) ==
             {:error, :not_found}

    assert Repo.get!(BiotRow, context.biot_id).access_revision == 1
    assert Repo.get!(BiotRow, other_biot_id).access_revision == 1
    assert_no_wake()
  end

  test "grants require a known principal", context do
    unknown = TestFixtures.id(PrincipalId, 9_999)
    assert {:ok, %Applied{}} = Publications.publish(context.actor, context.biot_id, context.port)

    assert Access.grant_shell(context.actor, context.biot_id, unknown) == {:error, :not_found}

    assert Access.grant_view(context.actor, context.biot_id, context.port, unknown) ==
             {:error, :not_found}

    assert Repo.get!(BiotRow, context.biot_id).access_revision == 1
    assert_no_wake()
  end

  test "every policy change rejects a non-owner", context do
    assert {:ok, %Applied{}} = Publications.publish(context.actor, context.biot_id, context.port)

    assert {:ok, %Applied{}} =
             Access.grant_shell(context.actor, context.biot_id, context.viewer.id)

    assert {:ok, %Applied{}} =
             Access.grant_view(context.actor, context.biot_id, context.port, context.viewer.id)

    assert_no_wake()

    changes = [
      fn ->
        Publications.publish(context.viewer_actor, context.biot_id, TestFixtures.port(4_001))
      end,
      fn ->
        Access.grant_shell(context.viewer_actor, context.biot_id, context.other_viewer.id)
      end,
      fn ->
        Access.grant_view(
          context.viewer_actor,
          context.biot_id,
          context.port,
          context.other_viewer.id
        )
      end,
      fn -> Access.revoke_shell(context.viewer_actor, context.biot_id, context.viewer.id) end,
      fn ->
        Access.revoke_view(
          context.viewer_actor,
          context.biot_id,
          context.port,
          context.viewer.id
        )
      end,
      fn -> Publications.unpublish(context.viewer_actor, context.biot_id, context.port) end
    ]

    for change <- changes do
      assert change.() == {:error, :forbidden}
    end

    assert Repo.get!(BiotRow, context.biot_id).access_revision == 1
    assert {:ok, [%{port: port}]} = Publications.discover(context.actor, context.biot_id)
    assert port == context.port

    assert {:ok, %AccessView{shell_grants: [shell_id], view_grants: [%{principal_id: view_id}]}} =
             Access.get_grants(context.actor, context.biot_id)

    assert shell_id == context.viewer.id
    assert view_id == context.viewer.id
    assert_no_wake()
  end

  test "every policy change rejects a destroyed Biot while reads still answer", context do
    assert {:ok, %Applied{}} = Publications.publish(context.actor, context.biot_id, context.port)

    assert {:ok, %Applied{}} =
             Access.grant_shell(context.actor, context.biot_id, context.viewer.id)

    assert {:ok, %Applied{}} =
             Access.grant_view(context.actor, context.biot_id, context.port, context.viewer.id)

    assert {:ok, %Accepted{}} = Biots.destroy(context.actor, context.biot_id)
    assert_one_wake(context.biot_id)

    changes = [
      fn -> Publications.publish(context.actor, context.biot_id, context.port) end,
      fn -> Publications.unpublish(context.actor, context.biot_id, context.port) end,
      fn -> Access.grant_shell(context.actor, context.biot_id, context.viewer.id) end,
      fn -> Access.revoke_shell(context.actor, context.biot_id, context.viewer.id) end,
      fn ->
        Access.grant_view(context.actor, context.biot_id, context.port, context.viewer.id)
      end,
      fn ->
        Access.revoke_view(context.actor, context.biot_id, context.port, context.viewer.id)
      end
    ]

    for change <- changes do
      assert change.() == {:error, :destroyed}
    end

    assert Publications.discover(context.actor, context.biot_id) == {:ok, []}

    assert Access.get_grants(context.actor, context.biot_id) ==
             {:ok, %AccessView{owner_id: context.owner.id, shell_grants: [], view_grants: []}}

    assert Repo.get!(BiotRow, context.biot_id).access_revision == 2
    assert_no_wake()
  end

  test "a shell-grant holder may discover but may not read grants", context do
    assert {:ok, %Applied{}} = Publications.publish(context.actor, context.biot_id, context.port)

    assert {:ok, %Applied{}} =
             Access.grant_shell(context.actor, context.biot_id, context.viewer.id)

    assert Publications.discover(context.viewer_actor, context.biot_id) == {:ok, []}
    assert Access.get_grants(context.viewer_actor, context.biot_id) == {:error, :forbidden}
    assert Publications.discover(context.other_actor, context.biot_id) == {:error, :forbidden}

    assert {:ok, %Applied{}} =
             Access.grant_view(context.actor, context.biot_id, context.port, context.viewer.id)

    assert {:ok, [%{port: port}]} = Publications.discover(context.viewer_actor, context.biot_id)
    assert port == context.port
    assert_no_wake()
  end

  test "revoking one principal preserves another principal's grant", context do
    assert {:ok, %Applied{}} = Publications.publish(context.actor, context.biot_id, context.port)

    assert {:ok, %Applied{}} =
             Access.grant_shell(context.actor, context.biot_id, context.viewer.id)

    assert {:ok, %Applied{}} =
             Access.grant_shell(context.actor, context.biot_id, context.other_viewer.id)

    assert_no_wake()

    assert {:ok, %Applied{} = revoked} =
             Access.revoke_shell(context.actor, context.biot_id, context.viewer.id)

    assert_policy(revoked, context, 2, {:pending, context.node.id})
    assert_one_wake(context.biot_id)

    assert {:ok, %AccessView{shell_grants: [remaining]}} =
             Access.get_grants(context.actor, context.biot_id)

    assert remaining == context.other_viewer.id
    assert Publications.discover(context.viewer_actor, context.biot_id) == {:error, :forbidden}
    assert Publications.discover(context.other_actor, context.biot_id) == {:ok, []}
  end

  test "an unknown Biot is not found by every policy operation", context do
    unknown = TestFixtures.id(BiotId, 9_999)

    calls = [
      fn -> Publications.publish(context.actor, unknown, context.port) end,
      fn -> Publications.unpublish(context.actor, unknown, context.port) end,
      fn -> Publications.discover(context.actor, unknown) end,
      fn -> Access.grant_shell(context.actor, unknown, context.viewer.id) end,
      fn -> Access.revoke_shell(context.actor, unknown, context.viewer.id) end,
      fn -> Access.grant_view(context.actor, unknown, context.port, context.viewer.id) end,
      fn -> Access.revoke_view(context.actor, unknown, context.port, context.viewer.id) end,
      fn -> Access.get_grants(context.actor, unknown) end
    ]

    for call <- calls do
      assert call.() == {:error, :not_found}
    end

    assert_no_wake()
  end

  test "current observation progress changes enforcement from pending to applied", context do
    current_connection = TestFixtures.connection_id(1)
    stale_connection = TestFixtures.connection_id(2)

    NodeConnections.put(context.node.id, %{
      connection_id: current_connection,
      state: :ready
    })

    assert {:ok, :stored} =
             Reports.observation(
               context.node.id,
               current_connection,
               context.biot_id,
               TestFixtures.execution_report(applied_access_revision: 1)
             )

    assert {:ok, %Applied{enforcement: :applied}} =
             Publications.publish(context.actor, context.biot_id, context.port)

    assert {:ok, %Applied{enforcement: :applied}} =
             Access.grant_view(context.actor, context.biot_id, context.port, context.viewer.id)

    assert {:ok, %Applied{access_revision: 2, enforcement: {:pending, node_id}}} =
             Access.revoke_view(context.actor, context.biot_id, context.port, context.viewer.id)

    assert node_id == context.node.id
    assert_one_wake(context.biot_id)

    assert {:ok, :stored} =
             Reports.observation(
               context.node.id,
               stale_connection,
               context.biot_id,
               TestFixtures.execution_report(applied_access_revision: 9)
             )

    assert {:ok, stale_view} = Queries.Biots.get(context.actor, context.biot_id)
    assert stale_view.access.enforcement == {:pending, context.node.id}

    assert {:ok, :stored} =
             Reports.observation(
               context.node.id,
               current_connection,
               context.biot_id,
               TestFixtures.execution_report(applied_access_revision: 2)
             )

    assert {:ok, current_view} = Queries.Biots.get(context.actor, context.biot_id)
    assert current_view.access == %{revision: 2, enforcement: :applied}

    assert {:ok, %Unchanged{access_revision: 2, enforcement: :applied}} =
             Access.revoke_view(context.actor, context.biot_id, context.port, context.viewer.id)

    assert_no_wake()
  end

  test "destroy removes policy records and advances the access revision once", context do
    assert {:ok, %Applied{}} = Publications.publish(context.actor, context.biot_id, context.port)

    assert {:ok, %Applied{}} =
             Access.grant_shell(context.actor, context.biot_id, context.viewer.id)

    assert {:ok, %Applied{}} =
             Access.grant_view(context.actor, context.biot_id, context.port, context.viewer.id)

    assert_no_wake()
    assert Repo.get!(BiotRow, context.biot_id).access_revision == 1

    assert {:ok, %Accepted{revision: 2}} = Biots.destroy(context.actor, context.biot_id)
    assert_one_wake(context.biot_id)

    rows = Repo.all(from(row in Publication, where: row.biot_id == ^context.biot_id))
    assert Enum.map(rows, & &1.state) == [:inactive]
    refute Repo.exists?(from(row in ShellGrant, where: row.biot_id == ^context.biot_id))
    refute Repo.exists?(from(row in ViewGrant, where: row.biot_id == ^context.biot_id))

    assert {:ok, view} = Queries.Biots.get(context.actor, context.biot_id)
    assert view.publications == []
    assert view.access.revision == 2
    assert view.desired.state == :destroyed
  end

  test "destroy deactivates every published port of this biot", context do
    other_port = TestFixtures.port(5_000)
    assert {:ok, %Applied{}} = Publications.publish(context.actor, context.biot_id, context.port)
    assert {:ok, %Applied{}} = Publications.publish(context.actor, context.biot_id, other_port)

    hostnames =
      Repo.all(from(row in Publication, where: row.biot_id == ^context.biot_id))
      |> Map.new(&{&1.port, &1.hostname})

    assert {:ok, %Accepted{revision: 2}} = Biots.destroy(context.actor, context.biot_id)

    rows = Repo.all(from(row in Publication, where: row.biot_id == ^context.biot_id))
    assert Enum.map(rows, & &1.state) == [:inactive, :inactive]
    assert Map.new(rows, &{&1.port, &1.hostname}) == hostnames
    assert Repo.get!(BiotRow, context.biot_id).access_revision == 2
  end

  defp create_biot(context, biot_id, name) do
    assert {:ok, %Accepted{}} =
             Biots.create(
               context.actor,
               biot_id,
               TestFixtures.create_command(name: name, node_id: context.node.id)
             )
  end

  defp assert_policy(result, context, revision, enforcement) do
    assert result.biot_id == context.biot_id
    assert result.access_revision == revision
    assert result.enforcement == enforcement
  end

  defp assert_one_wake(biot_id) do
    assert_receive {:biot_spec_changed, received_biot_id}
    assert received_biot_id == biot_id
    refute_receive {:biot_spec_changed, _biot_id}
  end

  defp assert_no_wake do
    refute_receive {:biot_spec_changed, _biot_id}
  end
end
