defmodule Biot.Server.AccessClosureIntegrationTest do
  @moduledoc false
  use Biot.Server.DataCase, async: false

  import Ecto.Query

  alias Biot.Protocol.{Message, SshPublicKey}
  alias Biot.Server.Access
  alias Biot.Server.Access.Owners
  alias Biot.Server.AccessHarness
  alias Biot.Server.AccessHarness.Registered
  alias Biot.Server.Actor
  alias Biot.Server.Authentication.Validity
  alias Biot.Server.Biots
  alias Biot.Server.Credentials
  alias Biot.Server.NodeConnections
  alias Biot.Server.Nodes
  alias Biot.Server.Nodes.Registration
  alias Biot.Server.NodeWake
  alias Biot.Server.Principals
  alias Biot.Server.Principals.DisabledIdentities.Identity
  alias Biot.Server.Publications
  alias Biot.Server.Schema.Biot, as: BiotRow

  alias Biot.Server.Schema.{
    AccessObservation,
    Credential,
    Node,
    Principal,
    Publication,
    Session,
    ShellGrant,
    SshKey,
    ViewGrant
  }

  alias Biot.Server.Sessions
  alias Biot.Server.SshKeys
  alias Biot.Server.TestFixtures
  alias Biot.Server.Tokens

  setup_all do
    directory = Path.join(System.tmp_dir!(), "biot-closure-#{System.unique_integer([:positive])}")
    {:ok, certificates} = TestFixtures.certificates(directory, 3)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{certificates: certificates}
  end

  setup %{certificates: certificates} do
    previous_principals = Application.fetch_env(:biot_server, :disabled_principals_file)
    previous_registrations = Application.fetch_env(:biot_server, :node_registrations_file)

    on_exit(fn ->
      restore_env(:disabled_principals_file, previous_principals)
      restore_env(:node_registrations_file, previous_registrations)
    end)

    listener_port = AccessHarness.start_listener(certificates)
    node_a = AccessHarness.node_row(1, certificates, 0)
    node_b = AccessHarness.node_row(2, certificates, 1)

    owner = TestFixtures.principal(1)
    collaborator = TestFixtures.principal(2)

    {biot, _environment} = TestFixtures.biot(owner, node_a, 1)
    {sibling, _environment} = TestFixtures.biot(owner, node_a, 2)
    {elsewhere, _environment} = TestFixtures.biot(owner, node_b, 3)
    port = TestFixtures.port(4_000)
    AccessHarness.publication(biot, port, TestFixtures.hostname(1))

    for target <- [biot, sibling, elsewhere], do: AccessHarness.shell_grant(target, collaborator)
    AccessHarness.view_grant(biot, port, collaborator)

    peer_a = AccessHarness.ready_peer(listener_port, certificates, node_a, 0)
    peer_b = AccessHarness.ready_peer(listener_port, certificates, node_b, 1)

    %{
      certificates: certificates,
      listener_port: listener_port,
      node_a: node_a,
      node_b: node_b,
      peer_a: peer_a,
      peer_b: peer_b,
      owner: owner,
      owner_actor: TestFixtures.actor(owner),
      collaborator: collaborator,
      biot: biot,
      sibling: sibling,
      elsewhere: elsewhere,
      port: port
    }
  end

  describe "policy withdrawal" do
    test "revoking a shell grant closes every owner of that Biot after commit, then wakes its node",
         context do
      assert_biot_closure(
        context,
        fn ->
          Access.revoke_shell(context.owner_actor, context.biot.id, context.collaborator.id)
        end,
        fn ->
          not Repo.exists?(
            from(g in ShellGrant,
              where: g.biot_id == ^context.biot.id and g.principal_id == ^context.collaborator.id
            )
          )
        end
      )
    end

    test "revoking a view grant closes every owner of that Biot after commit, then wakes its node",
         context do
      assert_biot_closure(
        context,
        fn ->
          Access.revoke_view(
            context.owner_actor,
            context.biot.id,
            context.port,
            context.collaborator.id
          )
        end,
        fn -> not Repo.exists?(from(g in ViewGrant, where: g.biot_id == ^context.biot.id)) end
      )
    end

    test "unpublishing closes every owner of that Biot after commit, then wakes its node",
         context do
      assert_biot_closure(
        context,
        fn -> Publications.unpublish(context.owner_actor, context.biot.id, context.port) end,
        fn ->
          Repo.get_by!(Publication, biot_id: context.biot.id, port: context.port).state ==
            :inactive
        end
      )
    end

    test "destroying closes every owner of that Biot after commit, then wakes its node",
         context do
      assert_biot_closure(
        context,
        fn -> Biots.destroy(context.owner_actor, context.biot.id) end,
        fn -> Repo.get!(BiotRow, context.biot.id).desired_state == :destroyed end
      )
    end

    test "adding access, an unchanged revoke, and lifecycle changes close no owner", context do
      newcomer = TestFixtures.principal(3)
      owners = owners_of(context, context.biot)

      assert {:ok, _} = Access.grant_shell(context.owner_actor, context.biot.id, newcomer.id)
      assert {:ok, _} = Publications.publish(context.owner_actor, context.biot.id, port(5_000))

      assert {:ok, _} =
               Access.grant_view(context.owner_actor, context.biot.id, port(5_000), newcomer.id)

      assert {:ok, _} = Access.revoke_shell(context.owner_actor, context.biot.id, newcomer.id)
      assert {:ok, _} = Access.revoke_shell(context.owner_actor, context.biot.id, newcomer.id)
      assert {:ok, _} = Biots.stop(context.owner_actor, context.biot.id, 1)

      # The one revoke that withdrew a grant closes; the unchanged revoke and the rest do not.
      for pid <- owners, do: assert_receive({:closed, ^pid, _observed})
      for pid <- owners, do: refute_receive({:closed, ^pid, _observed}, 200)
      assert access_revision(context.biot) == 2
    end
  end

  test "disabling a principal closes its owners on every Biot after commit, then wakes those Biots",
       context do
    {_token, control} = AccessHarness.control(context.collaborator)
    credential = credential_authentication(context.collaborator)
    ssh = ssh_authentication(context.collaborator)
    {_token, bystander_control} = AccessHarness.control(context.owner)

    probe = fn ->
      Repo.get!(Principal, context.collaborator.id).status == :disabled and
        not Repo.exists?(from(s in Session, where: s.principal_id == ^context.collaborator.id)) and
        access_revision(context.biot) == 2
    end

    disabled = [
      Registered.start(context.biot.id, control, probe),
      Registered.start(context.sibling.id, credential, probe),
      Registered.start(context.elsewhere.id, ssh, probe)
    ]

    bystander = Registered.start(context.biot.id, bystander_control, probe)
    register_self(context.biot, control)
    :ok = NodeWake.subscribe(context.node_a.id)

    TestFixtures.put_disabled_principals([
      %Identity{issuer: context.collaborator.issuer, subject: context.collaborator.subject}
    ])

    assert :ok = Principals.reload()

    for pid <- disabled, do: assert_receive({:closed, ^pid, true})
    refute_receive {:closed, ^bystander, _observed}, 200
    assert first_close_or_wake() == :close
    assert_desired(context.peer_a, [context.biot.id, context.sibling.id], 2)
    assert_desired(context.peer_b, [context.elsewhere.id], 2)
  end

  test "disabling a node closes the owners of its Biots after commit and closes its connection without a spec",
       context do
    {_token, control} = AccessHarness.control(context.owner)

    probe = fn ->
      Repo.get!(Node, context.node_a.id).status == :disabled and
        access_revision(context.biot) == 2 and access_revision(context.sibling) == 2
    end

    on_node_a = [
      Registered.start(context.biot.id, control, probe),
      Registered.start(context.sibling.id, control, probe)
    ]

    on_node_b = Registered.start(context.elsewhere.id, control, probe)

    TestFixtures.put_registrations([
      registration(context.node_a, :disabled),
      registration(context.node_b, :enabled)
    ])

    assert {:ok, _nodes} = Nodes.reload()

    for pid <- on_node_a, do: assert_receive({:closed, ^pid, true})
    refute_receive {:closed, ^on_node_b, _observed}, 200

    messages = AccessHarness.messages_until_closed(context.peer_a)
    refute Enum.any?(messages, &match?(%Message.Desired{}, &1)), inspect(messages)
    assert %{state: :ready} = NodeConnections.current(context.node_b.id)
  end

  describe "the access sweep" do
    test "its timer closes the owners of a Biot behind on access until the node applies it",
         context do
      listener_port =
        AccessHarness.start_listener(context.certificates, desired_sweep_interval_ms: 100)

      node = AccessHarness.node_row(3, context.certificates, 2)
      {behind, _environment} = TestFixtures.biot(context.owner, node, 4)
      {caught_up, _environment} = TestFixtures.biot(context.owner, node, 5)
      peer = AccessHarness.ready_peer(listener_port, context.certificates, node, 2)
      {_token, control} = AccessHarness.control(context.owner)

      behind_owner = Registered.start(behind.id, control, fn -> access_revision(behind) end)
      caught_up_owner = Registered.start(caught_up.id, control, fn -> nil end)

      # A withdrawal committed, but its request process died before it closed any owner.
      bump_access_revision(behind)

      assert_receive {:closed, ^behind_owner, 2}, 1_000
      assert_desired(peer, [behind.id], 2)
      refute_receive {:closed, ^caught_up_owner, _observed}, 300

      AccessHarness.apply_access(peer, behind.id, 2)

      AccessHarness.wait_until(fn ->
        match?(
          %AccessObservation{applied_access_revision: 2},
          Repo.get(AccessObservation, behind.id)
        )
      end)

      flush_closes(behind_owner)
      later_owner = Registered.start(behind.id, control)
      refute_receive {:closed, ^later_owner, _observed}, 400
    end

    test "a node reconnection closes the owners of a Biot behind on access", context do
      listener_port = AccessHarness.start_listener(context.certificates)
      node = AccessHarness.node_row(3, context.certificates, 2)
      {behind, _environment} = TestFixtures.biot(context.owner, node, 4)
      {caught_up, _environment} = TestFixtures.biot(context.owner, node, 5)
      _peer = AccessHarness.ready_peer(listener_port, context.certificates, node, 2)
      {_token, control} = AccessHarness.control(context.owner)

      behind_owner = Registered.start(behind.id, control, fn -> access_revision(behind) end)
      caught_up_owner = Registered.start(caught_up.id, control)
      bump_access_revision(behind)
      refute_receive {:closed, ^behind_owner, _observed}, 200

      _reconnected = AccessHarness.ready_peer(listener_port, context.certificates, node, 2)

      assert_receive {:closed, ^behind_owner, 2}
      refute_receive {:closed, ^caught_up_owner, _observed}, 200
    end
  end

  describe "proof deletion" do
    test "logout closes the owners of that login and its previews, and no other login's",
         context do
      {token, login} = AccessHarness.control(context.collaborator)
      {:control, digest, _expires_at} = login.proof
      preview = preview_authentication(context.collaborator, digest)
      {_token, other_login} = AccessHarness.control(context.collaborator)
      credential = credential_authentication(context.collaborator)

      probe = fn -> not Repo.exists?(from(s in Session, where: s.id_digest == ^digest)) end

      closed = [
        Registered.start(context.biot.id, login, probe),
        Registered.start(context.biot.id, preview, probe)
      ]

      kept = [
        Registered.start(context.biot.id, other_login),
        Registered.start(context.biot.id, credential)
      ]

      assert :ok = Sessions.logout(token)

      for pid <- closed, do: assert_receive({:closed, ^pid, true})
      for pid <- kept, do: refute_receive({:closed, ^pid, _observed}, 200)
      refute Repo.exists?(from(s in Session, where: s.control_session_digest == ^digest))
    end

    test "credential revocation closes the owners of that credential and no other", context do
      first = credential_authentication(context.collaborator)
      second = credential_authentication(context.collaborator)
      {:credential, credential_id, _expires_at} = first.proof

      revoked =
        Registered.start(context.biot.id, first, fn ->
          is_nil(Repo.get(Credential, credential_id))
        end)

      kept = Registered.start(context.biot.id, second)

      assert :ok = Credentials.revoke(collaborator_actor(context), credential_id)
      assert_receive {:closed, ^revoked, true}
      refute_receive {:closed, ^kept, _observed}, 200
    end

    test "SSH key removal closes the owners of that key and no other", context do
      first = ssh_authentication(context.collaborator)
      second = ssh_authentication(context.collaborator)
      {:ssh_key, key_id} = first.proof

      removed =
        Registered.start(context.biot.id, first, fn -> is_nil(Repo.get(SshKey, key_id)) end)

      kept = Registered.start(context.biot.id, second)

      assert :ok = SshKeys.remove(collaborator_actor(context), key_id)
      assert_receive {:closed, ^removed, true}
      refute_receive {:closed, ^kept, _observed}, 200
    end

    test "a delete that finds nothing closes no owner", context do
      credential = credential_authentication(context.collaborator)
      ssh = ssh_authentication(context.collaborator)
      {:credential, credential_id, _expires_at} = credential.proof
      {:ssh_key, key_id} = ssh.proof

      owners = [
        Registered.start(context.biot.id, credential),
        Registered.start(context.biot.id, ssh)
      ]

      stranger = TestFixtures.actor(TestFixtures.principal(5))

      assert {:error, :not_found} = Credentials.revoke(stranger, credential_id)
      assert {:error, :not_found} = SshKeys.remove(stranger, key_id)
      for pid <- owners, do: refute_receive({:closed, ^pid, _observed}, 200)
    end
  end

  # Registers owners of `biot` and of a sibling Biot, runs `change`, and checks that exactly the
  # owners of `biot` close, each seeing the committed change, before the node receives the spec.
  defp assert_biot_closure(context, change, committed?) do
    {_token, collaborator_control} = AccessHarness.control(context.collaborator)
    {_token, owner_control} = AccessHarness.control(context.owner)
    probe = fn -> committed?.() and access_revision(context.biot) == 2 end

    affected = [
      Registered.start(context.biot.id, collaborator_control, probe),
      Registered.start(context.biot.id, owner_control, probe)
    ]

    unaffected = [
      Registered.start(context.sibling.id, collaborator_control, probe),
      Registered.start(context.elsewhere.id, owner_control, probe)
    ]

    register_self(context.biot, owner_control)
    :ok = NodeWake.subscribe(context.node_a.id)

    assert {:ok, _result} = change.()

    for pid <- affected, do: assert_receive({:closed, ^pid, true})
    for pid <- unaffected, do: refute_receive({:closed, ^pid, _observed}, 200)
    assert first_close_or_wake() == :close
    assert_desired(context.peer_a, [context.biot.id], 2)
  end

  defp owners_of(context, biot) do
    {_token, control} = AccessHarness.control(context.collaborator)
    [Registered.start(biot.id, control)]
  end

  # The test process registers as an owner and subscribes to the node's wakes, so its own mailbox
  # shows whether the close was sent before the wake.
  defp register_self(biot, authentication) do
    :ok =
      Owners.register(
        biot.id,
        authentication.actor.principal_id,
        Validity.proof_keys(authentication)
      )
  end

  defp first_close_or_wake do
    receive do
      {:biot_access, :close} -> :close
      {:biot_spec_changed, _biot_id} -> :wake
    after
      1_000 -> :neither
    end
  end

  defp assert_desired(peer, biot_ids, access_revision) do
    received =
      for _biot_id <- biot_ids do
        %Message.Desired{biot_spec: spec} = AccessHarness.await_message(peer, Message.Desired)
        assert spec.access_revision == access_revision
        spec.execution.biot_id
      end

    assert Enum.sort(received) == Enum.sort(biot_ids)
  end

  defp flush_closes(pid) do
    receive do
      {:closed, ^pid, _observed} -> flush_closes(pid)
    after
      0 -> :ok
    end
  end

  defp preview_authentication(principal, parent_digest) do
    {token, digest} = Tokens.mint()

    Repo.insert!(%Session{
      id_digest: digest,
      principal_id: principal.id,
      scope: :preview,
      hostname: TestFixtures.hostname(1),
      control_session_digest: parent_digest,
      expires_at: DateTime.add(DateTime.utc_now(), 3_600)
    })

    {:ok, authentication} = Sessions.preview(TestFixtures.hostname(1), token)
    authentication
  end

  defp credential_authentication(principal) do
    {_token, control} = AccessHarness.control(principal)

    {:ok, created} =
      Credentials.create(control, "closure", DateTime.add(DateTime.utc_now(), 3_600))

    {:ok, authentication} = Credentials.authenticate(created.token)
    authentication
  end

  defp ssh_authentication(principal) do
    {public, _private} = :crypto.generate_key(:eddsa, :ed25519)
    blob = <<11::32, "ssh-ed25519", byte_size(public)::32, public::binary>>
    line = "ssh-ed25519 " <> Base.encode64(blob)
    {:ok, _view} = SshKeys.add(%Actor{principal_id: principal.id}, line, "closure")
    {:ok, public_key} = SshPublicKey.parse(line)
    {:ok, authentication} = SshKeys.authenticate(public_key)
    authentication
  end

  defp collaborator_actor(context), do: %Actor{principal_id: context.collaborator.id}

  defp registration(%Node{} = node, status) do
    %Registration{
      node_id: node.id,
      registration_id: node.registration,
      peer_identity: node.peer_identity,
      max_biots: node.max_biots,
      status: status
    }
  end

  defp access_revision(biot), do: Repo.get!(BiotRow, biot.id).access_revision

  defp bump_access_revision(biot) do
    {1, _} =
      Repo.update_all(from(b in BiotRow, where: b.id == ^biot.id), inc: [access_revision: 1])

    :ok
  end

  defp port(number), do: TestFixtures.port(number)

  defp restore_env(key, {:ok, value}), do: Application.put_env(:biot_server, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:biot_server, key)
end
