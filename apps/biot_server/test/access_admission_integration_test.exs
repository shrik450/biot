defmodule Biot.Server.AccessAdmissionIntegrationTest do
  @moduledoc false
  use Biot.Server.DataCase, async: false

  import Ecto.Query

  alias Biot.Protocol.{BiotId, ShellRequest, SshPublicKey}
  alias Biot.Server.Access
  alias Biot.Server.Access.Owners
  alias Biot.Server.AccessHarness
  alias Biot.Server.AccessHarness.Owner
  alias Biot.Server.Actor
  alias Biot.Server.Authentication
  alias Biot.Server.AuthenticationProof
  alias Biot.Server.Credentials
  alias Biot.Server.NodeConnections
  alias Biot.Server.Schema.Biot, as: BiotRow
  alias Biot.Server.Schema.{Principal, Publication, Session, ShellGrant, SshKey}
  alias Biot.Server.Sessions
  alias Biot.Server.SshKeys
  alias Biot.Server.Streams.Stream
  alias Biot.Server.TestFixtures
  alias Biot.Server.Tokens

  @shell %ShellRequest{term: "xterm", cols: 80, rows: 24, command: nil}
  @open_timeout_ms 300
  @ssh_key "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINzyzz1M9L5KLhn5k5Lh3Peq0ipDgKB4DPAJ0A7UqS06"

  setup_all do
    directory =
      Path.join(System.tmp_dir!(), "biot-admission-#{System.unique_integer([:positive])}")

    {:ok, certificates} = TestFixtures.certificates(directory, 2)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{certificates: certificates}
  end

  setup %{certificates: certificates} do
    previous = Application.get_env(:biot_server, :stream_open_timeout_ms)
    Application.put_env(:biot_server, :stream_open_timeout_ms, @open_timeout_ms)
    on_exit(fn -> Application.put_env(:biot_server, :stream_open_timeout_ms, previous) end)

    listener_port = AccessHarness.start_listener(certificates)
    node = AccessHarness.node_row(1, certificates, 0)

    owner = TestFixtures.principal(1)
    collaborator = TestFixtures.principal(2)
    viewer = TestFixtures.principal(3)
    stranger = TestFixtures.principal(4)

    {biot, _environment} = TestFixtures.biot(owner, node, 1)
    AccessHarness.shell_grant(biot, collaborator)
    port = TestFixtures.port(4_000)
    hostname = TestFixtures.hostname(1)
    AccessHarness.publication(biot, port, hostname)
    AccessHarness.view_grant(biot, port, viewer)

    peer = AccessHarness.ready_peer(listener_port, certificates, node, 0)

    %{
      certificates: certificates,
      listener_port: listener_port,
      node: node,
      peer: peer,
      owner: owner,
      collaborator: collaborator,
      viewer: viewer,
      stranger: stranger,
      biot: biot,
      port: port,
      hostname: hostname
    }
  end

  describe "an admitted owner" do
    test "the node receives the committed revision and the shell target on the current connection",
         context do
      {_token, authentication} = AccessHarness.control(context.collaborator)
      owner = Owner.start()

      %{open: open, stream: stream} =
        admit_through_peer(context.peer, owner, shell(authentication, context.biot))

      assert open.biot_id == context.biot.id
      assert open.access_revision == 1
      assert open.target == {:shell, @shell}
      assert open.connection_id == context.peer.connection_id
      assert %Stream{kind: :shell, id: stream_id} = stream
      assert stream_id == open.stream_id
    end

    test "the Biot owner needs no grant to open a shell", context do
      {_token, authentication} = AccessHarness.control(context.owner)
      owner = Owner.start()

      %{stream: stream} =
        admit_through_peer(context.peer, owner, shell(authentication, context.biot))

      assert stream.kind == :shell
    end

    test "a shell owner is closed through each of its Biot, principal, and control session keys",
         context do
      {_token, authentication} = AccessHarness.control(context.collaborator)
      {:control, digest, _expires_at} = authentication.proof

      for key <- [
            {:biot, context.biot.id},
            {:principal, context.collaborator.id},
            {:control_session, digest}
          ] do
        owner = Owner.start()

        %{attach: attach} =
          admit_through_peer(context.peer, owner, shell(authentication, context.biot))

        :ok = Owners.close(key)
        assert_receive {:owner_closed, ^owner, :policy, _observed}, 2_000, inspect(key)
        assert AccessHarness.closed?(attach), inspect(key)
        assert AccessHarness.registered_keys(owner) == [], inspect(key)
      end
    end

    test "a viewer's preview opens the published port and is closed by its keys", context do
      {_token, authentication} = AccessHarness.control(context.viewer)
      {:control, digest, _expires_at} = authentication.proof

      for key <- [
            {:biot, context.biot.id},
            {:principal, context.viewer.id},
            {:control_session, digest}
          ] do
        owner = Owner.start()

        %{open: open, attach: attach, stream: stream} =
          admit_through_peer(context.peer, owner, preview(authentication, context.hostname))

        assert open.target == {:port, context.port}
        assert open.biot_id == context.biot.id
        assert stream.kind == :port

        :ok = Owners.close(key)
        assert_receive {:owner_closed, ^owner, :policy, _observed}, 2_000, inspect(key)
        assert AccessHarness.closed?(attach), inspect(key)
      end
    end

    test "a preview-session owner is closed by its preview session and by its parent login",
         context do
      {preview_digest, parent_digest, authentication} =
        preview_authentication(context.viewer, context.hostname, hours(1), hours(1))

      for key <- [{:preview_session, preview_digest}, {:control_session, parent_digest}] do
        owner = Owner.start()

        %{attach: attach} =
          admit_through_peer(context.peer, owner, preview(authentication, context.hostname))

        :ok = Owners.close(key)
        assert_receive {:owner_closed, ^owner, :policy, _observed}, 2_000, inspect(key)
        assert AccessHarness.closed?(attach), inspect(key)
      end
    end

    test "credential and SSH key owners are closed through their proof keys", context do
      credential_authentication = credential_authentication(context.collaborator)
      {:credential, credential_id, _expires_at} = credential_authentication.proof
      ssh_authentication = ssh_authentication(context.collaborator)
      {:ssh_key, key_id} = ssh_authentication.proof

      for {authentication, key} <- [
            {credential_authentication, {:credential, credential_id}},
            {ssh_authentication, {:ssh_key, key_id}}
          ] do
        owner = Owner.start()

        %{attach: attach} =
          admit_through_peer(context.peer, owner, shell(authentication, context.biot))

        :ok = Owners.close(key)
        assert_receive {:owner_closed, ^owner, :policy, _observed}, 2_000, inspect(key)
        assert AccessHarness.closed?(attach), inspect(key)
      end
    end
  end

  describe "denied admission" do
    test "a principal without shell authority is forbidden before any open", context do
      {_token, viewer_authentication} = AccessHarness.control(context.viewer)
      {_token, stranger_authentication} = AccessHarness.control(context.stranger)

      for authentication <- [viewer_authentication, stranger_authentication] do
        assert_denied(context, shell(authentication, context.biot), :forbidden)
      end
    end

    test "a principal without shell authority learns nothing about the Biot or its node",
         context do
      disabled_node = AccessHarness.node_row(2, context.certificates, 1, status: :disabled)
      {on_disabled, _environment} = TestFixtures.biot(context.owner, disabled_node, 3)

      {destroyed, _environment} =
        TestFixtures.biot(context.owner, context.node, 2, desired_state: :destroyed)

      {_token, stranger_authentication} = AccessHarness.control(context.stranger)

      assert_denied(context, shell(stranger_authentication, on_disabled), :forbidden)
      assert_denied(context, shell(stranger_authentication, destroyed), :forbidden)
    end

    test "a principal without a view grant on the port is forbidden", context do
      {_token, collaborator_authentication} = AccessHarness.control(context.collaborator)
      {_token, stranger_authentication} = AccessHarness.control(context.stranger)

      for authentication <- [collaborator_authentication, stranger_authentication] do
        assert_denied(context, preview(authentication, context.hostname), :forbidden)
      end
    end

    test "every dead or mismatched proof is unauthenticated", context do
      {_token, expired} = AccessHarness.control(context.collaborator)
      {:control, expired_digest, _expires_at} = expired.proof
      set_session_expiry(expired_digest, DateTime.add(DateTime.utc_now(), -1, :second))

      {logged_out_token, logged_out} = AccessHarness.control(context.collaborator)
      :ok = Sessions.logout(logged_out_token)

      {_token, strangers} = AccessHarness.control(context.stranger)

      borrowed = %Authentication{
        actor: %Actor{principal_id: context.collaborator.id},
        proof: strangers.proof
      }

      missing = %Authentication{
        actor: %Actor{principal_id: context.collaborator.id},
        proof: AuthenticationProof.control(Tokens.digest("no-such-session"), hours(1))
      }

      removed_key = ssh_authentication(context.collaborator)
      {:ssh_key, key_id} = removed_key.proof
      :ok = SshKeys.remove(%Actor{principal_id: context.collaborator.id}, key_id)

      for {label, authentication} <- [
            {"expired session", expired},
            {"logged-out session", logged_out},
            {"another principal's session", borrowed},
            {"missing session", missing},
            {"removed SSH key", removed_key}
          ] do
        assert_denied(context, shell(authentication, context.biot), :unauthenticated, label)
      end
    end

    test "a disabled principal's live-looking proofs are unauthenticated", context do
      {_token, control} = AccessHarness.control(context.collaborator)
      credential = credential_authentication(context.collaborator)
      ssh = ssh_authentication(context.collaborator)

      Repo.update_all(from(p in Principal, where: p.id == ^context.collaborator.id),
        set: [status: :disabled]
      )

      for authentication <- [control, credential, ssh] do
        assert_denied(context, shell(authentication, context.biot), :unauthenticated)
      end
    end

    test "a preview proof whose parent login ended is unauthenticated", context do
      {_preview_digest, parent_digest, authentication} =
        preview_authentication(context.viewer, context.hostname, hours(1), hours(1))

      Repo.delete_all(from(s in Session, where: s.id_digest == ^parent_digest))

      assert_denied(context, preview(authentication, context.hostname), :unauthenticated)
    end

    test "a preview proof for one host does not open another host", context do
      other_port = TestFixtures.port(5_000)
      other_hostname = TestFixtures.hostname(2)
      AccessHarness.publication(context.biot, other_port, other_hostname)
      AccessHarness.view_grant(context.biot, other_port, context.viewer)

      {_preview_digest, _parent_digest, authentication} =
        preview_authentication(context.viewer, context.hostname, hours(1), hours(1))

      result = Access.open_preview(authentication, other_hostname)

      # Model section 5: "a preview session cannot act on the control host or another preview
      # host".
      assert result in [{:error, :unauthenticated}, {:error, :forbidden}], inspect(result)
    end

    test "a preview proof does not open a shell", context do
      {_preview_digest, _parent_digest, authentication} =
        preview_authentication(context.owner, context.hostname, hours(1), hours(1))

      result = Access.open_shell(authentication, context.biot.id, @shell)

      # Model section 5: "a preview session cannot act on the control host or another preview
      # host".
      assert result in [{:error, :unauthenticated}, {:error, :forbidden}], inspect(result)
    end

    test "an unknown or destroyed Biot and an unpublished host are not found", context do
      {_token, owner_authentication} = AccessHarness.control(context.owner)
      {_token, viewer_authentication} = AccessHarness.control(context.viewer)

      {destroyed, _environment} =
        TestFixtures.biot(context.owner, context.node, 2, desired_state: :destroyed)

      inactive_hostname = TestFixtures.hostname(3)
      inactive_port = TestFixtures.port(6_000)

      Repo.insert!(%Publication{
        biot_id: context.biot.id,
        port: inactive_port,
        hostname: inactive_hostname,
        state: :inactive
      })

      assert_denied(
        context,
        fn ->
          Access.open_shell(owner_authentication, BiotId.generate(), @shell)
        end,
        :not_found
      )

      assert_denied(context, shell(owner_authentication, destroyed), :not_found)
      assert_denied(context, preview(viewer_authentication, TestFixtures.hostname(9)), :not_found)
      assert_denied(context, preview(viewer_authentication, inactive_hostname), :not_found)
    end

    test "a disabled node and a node with no ready connection are unavailable", context do
      disabled_node = AccessHarness.node_row(2, context.certificates, 1, status: :disabled)
      {on_disabled, _environment} = TestFixtures.biot(context.owner, disabled_node, 3)
      disabled_hostname = TestFixtures.hostname(4)
      AccessHarness.publication(on_disabled, context.port, disabled_hostname)
      AccessHarness.view_grant(on_disabled, context.port, context.viewer)

      idle_node = TestFixtures.node(3)
      {on_idle, _environment} = TestFixtures.biot(context.owner, idle_node, 4)

      {_token, owner_authentication} = AccessHarness.control(context.owner)
      {_token, viewer_authentication} = AccessHarness.control(context.viewer)
      {_token, stranger_authentication} = AccessHarness.control(context.stranger)

      assert_denied(context, shell(owner_authentication, on_disabled), :node_unavailable)

      assert_denied(
        context,
        preview(viewer_authentication, disabled_hostname),
        :node_unavailable
      )

      # A caller without view authority learns nothing about the node.
      assert_denied(context, preview(stranger_authentication, disabled_hostname), :forbidden)
      assert_denied(context, shell(owner_authentication, on_idle), :node_unavailable)
    end

    test "each node refusal reaches the caller and leaves no owner registered", context do
      {_token, authentication} = AccessHarness.control(context.owner)

      for {reason, expected} <- [
            unknown_biot: :not_found,
            agent_unreachable: :agent_unreachable,
            port_not_listening: :port_not_listening,
            too_many_streams: :too_many_streams
          ] do
        owner = Owner.start()
        Owner.admit(owner, shell(authentication, context.biot))
        open = AccessHarness.await_open(context.peer)
        AccessHarness.refuse(context.peer, open.stream_id, reason)
        assert Owner.await_admitted(owner) == {:error, expected}, inspect(reason)
        assert AccessHarness.registered_keys(owner) == [], inspect(reason)
      end
    end
  end

  describe "admission races" do
    test "a close that arrives while the owner checks policy stops admission before any open",
         context do
      {_token, authentication} = AccessHarness.control(context.collaborator)
      parent = self()

      # The sandbox connection is shared, so this transaction holds the owner's snapshot read
      # until the test releases it.
      blocker =
        Task.async(fn ->
          Repo.transaction(fn ->
            send(parent, :holding)

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive :holding
      owner = Owner.start()
      Owner.admit(owner, shell(authentication, context.biot))
      AccessHarness.wait_until(fn -> AccessHarness.registered_keys(owner) != [] end)

      :ok = Owners.close_biot(context.biot.id)
      send(blocker.pid, :release)
      Task.await(blocker)

      assert Owner.await_admitted(owner) == {:error, :forbidden}
      AccessHarness.no_message(context.peer, Biot.Protocol.Message.OpenStream, 300)
      assert AccessHarness.registered_keys(owner) == []
    end

    test "a close that arrives while the stream opens closes the stream as it arrives", context do
      {_token, authentication} = AccessHarness.control(context.collaborator)
      owner = Owner.start()
      Owner.admit(owner, shell(authentication, context.biot))
      open = AccessHarness.await_open(context.peer)

      :ok = Owners.close_biot(context.biot.id)
      attach = AccessHarness.attach(context.peer, open.stream_id)

      assert Owner.await_admitted(owner) == {:error, :forbidden}
      assert AccessHarness.closed?(attach)
      assert AccessHarness.registered_keys(owner) == []
    end

    test "a stale revision rereads policy and retries once with the new revision", context do
      {_token, authentication} = AccessHarness.control(context.collaborator)
      owner = Owner.start()
      Owner.admit(owner, shell(authentication, context.biot))

      first = AccessHarness.await_open(context.peer)
      assert first.access_revision == 1
      bump_access_revision(context.biot)
      AccessHarness.refuse(context.peer, first.stream_id, :stale_access)

      second = AccessHarness.await_open(context.peer)
      assert second.access_revision == 2
      refute second.stream_id == first.stream_id

      _attach = AccessHarness.attach(context.peer, second.stream_id)
      assert {:ok, %Stream{id: stream_id}} = Owner.await_admitted(owner)
      assert stream_id == second.stream_id
    end

    test "a stale admission waits for an applied-revision signal and then succeeds", context do
      {_token, authentication} = AccessHarness.control(context.collaborator)
      owner = Owner.start()
      Owner.admit(owner, shell(authentication, context.biot))

      first = AccessHarness.await_open(context.peer)
      bump_access_revision(context.biot)
      AccessHarness.refuse(context.peer, first.stream_id, :stale_access)

      second = AccessHarness.await_open(context.peer)
      assert second.access_revision == 2
      AccessHarness.refuse(context.peer, second.stream_id, :stale_access)
      AccessHarness.no_message(context.peer, Biot.Protocol.Message.OpenStream, 100)
      AccessHarness.apply_access(context.peer, context.biot.id, 2)

      third = AccessHarness.await_open(context.peer)
      assert third.access_revision == 2
      _attach = AccessHarness.attach(context.peer, third.stream_id)
      assert {:ok, %Stream{id: stream_id}} = Owner.await_admitted(owner)
      assert stream_id == third.stream_id
    end

    test "a withdrawn grant during a stale wait answers forbidden", context do
      {_token, authentication} = AccessHarness.control(context.collaborator)
      owner = Owner.start()
      Owner.admit(owner, shell(authentication, context.biot))

      first = AccessHarness.await_open(context.peer)
      bump_access_revision(context.biot)
      AccessHarness.refuse(context.peer, first.stream_id, :stale_access)

      second = AccessHarness.await_open(context.peer)
      AccessHarness.refuse(context.peer, second.stream_id, :stale_access)

      Repo.delete_all(
        from(g in ShellGrant,
          where: g.biot_id == ^context.biot.id and g.principal_id == ^context.collaborator.id
        )
      )

      bump_access_revision(context.biot)
      AccessHarness.apply_access(context.peer, context.biot.id, 3)

      assert Owner.await_admitted(owner) == {:error, :forbidden}
      AccessHarness.no_message(context.peer, Biot.Protocol.Message.OpenStream, 100)
      assert AccessHarness.registered_keys(owner) == []
    end

    test "a stale admission returns timeout only when its deadline expires without a signal",
         context do
      {_token, authentication} = AccessHarness.control(context.collaborator)
      owner = Owner.start()
      started = System.monotonic_time(:millisecond)
      Owner.admit(owner, shell(authentication, context.biot))

      first = AccessHarness.await_open(context.peer)
      bump_access_revision(context.biot)
      AccessHarness.refuse(context.peer, first.stream_id, :stale_access)

      second = AccessHarness.await_open(context.peer)
      AccessHarness.refuse(context.peer, second.stream_id, :stale_access)

      assert Owner.await_admitted(owner, 2_000) == {:error, :timeout}
      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed >= @open_timeout_ms - 50, "admission returned too early after #{elapsed} ms"
      assert elapsed < @open_timeout_ms + 300, "admission took #{elapsed} ms"
      AccessHarness.no_message(context.peer, Biot.Protocol.Message.OpenStream, 100)
      assert AccessHarness.registered_keys(owner) == []
    end

    test "the retry uses what is left of the first open's deadline", context do
      {_token, authentication} = AccessHarness.control(context.collaborator)
      owner = Owner.start()
      started = System.monotonic_time(:millisecond)
      Owner.admit(owner, shell(authentication, context.biot))

      first = AccessHarness.await_open(context.peer)
      AccessHarness.pause(div(@open_timeout_ms * 6, 10))
      AccessHarness.refuse(context.peer, first.stream_id, :stale_access)
      _second = AccessHarness.await_open(context.peer)

      assert Owner.await_admitted(owner, 5_000) == {:error, :timeout}
      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed < @open_timeout_ms + 300, "admission took #{elapsed} ms"
    end

    test "an old admission after the node applied a withdrawal rereads policy and is denied",
         context do
      {_token, authentication} = AccessHarness.control(context.collaborator)
      owner = Owner.start()
      Owner.admit(owner, shell(authentication, context.biot))
      open = AccessHarness.await_open(context.peer)
      assert open.access_revision == 1

      # A withdrawal committed, but its request process died before it closed any owner.
      Repo.delete_all(
        from(g in ShellGrant,
          where: g.biot_id == ^context.biot.id and g.principal_id == ^context.collaborator.id
        )
      )

      bump_access_revision(context.biot)
      AccessHarness.refuse(context.peer, open.stream_id, :stale_access)

      assert Owner.await_admitted(owner) == {:error, :forbidden}
      AccessHarness.no_message(context.peer, Biot.Protocol.Message.OpenStream, 300)
      assert AccessHarness.registered_keys(owner) == []
    end

    test "an old admission whose proof ended meanwhile is unauthenticated on the reread",
         context do
      {_token, authentication} = AccessHarness.control(context.collaborator)
      owner = Owner.start()
      Owner.admit(owner, shell(authentication, context.biot))
      open = AccessHarness.await_open(context.peer)

      {:control, digest, _expires_at} = authentication.proof
      Repo.delete_all(from(s in Session, where: s.id_digest == ^digest))
      AccessHarness.refuse(context.peer, open.stream_id, :stale_access)

      assert Owner.await_admitted(owner) == {:error, :unauthenticated}
      AccessHarness.no_message(context.peer, Biot.Protocol.Message.OpenStream, 300)
    end
  end

  describe "absolute expiry" do
    test "a control-session owner closes when its session expires", context do
      {_token, authentication} = AccessHarness.control(context.collaborator)
      {:control, digest, _expires_at} = authentication.proof
      set_session_expiry(digest, DateTime.add(DateTime.utc_now(), 600, :millisecond))

      owner = Owner.start()

      %{attach: attach} =
        admit_through_peer(context.peer, owner, shell(authentication, context.biot))

      refute_receive {:owner_closed, ^owner, _reason, _observed}, 300
      assert_receive {:owner_closed, ^owner, :expired, nil}, 2_000
      assert AccessHarness.closed?(attach)
      assert AccessHarness.registered_keys(owner) == []
    end

    test "a preview owner closes when its parent login expires, even if the preview row lasts",
         context do
      {_preview_digest, _parent_digest, authentication} =
        preview_authentication(
          context.viewer,
          context.hostname,
          DateTime.add(DateTime.utc_now(), 600, :millisecond),
          hours(1)
        )

      owner = Owner.start()

      %{attach: attach} =
        admit_through_peer(context.peer, owner, preview(authentication, context.hostname))

      assert_receive {:owner_closed, ^owner, :expired, nil}, 2_000
      assert AccessHarness.closed?(attach)
    end

    test "an SSH key owner has no absolute expiry", context do
      authentication = ssh_authentication(context.collaborator)
      owner = Owner.start()
      admit_through_peer(context.peer, owner, shell(authentication, context.biot))
      refute_receive {:owner_closed, ^owner, _reason, _observed}, 800
    end
  end

  describe "control loss" do
    test "owners close when the admitting control connection exits, and no stale entry remains",
         context do
      {_token, authentication} = AccessHarness.control(context.collaborator)
      owner = Owner.start()

      %{attach: attach, stream: stream} =
        admit_through_peer(context.peer, owner, shell(authentication, context.biot))

      connection_pid = stream.connection_pid
      assert NodeConnections.connection_pid(context.node.id) == connection_pid
      reference = Process.monitor(connection_pid)
      Process.exit(connection_pid, :kill)
      assert_receive {:DOWN, ^reference, :process, ^connection_pid, :killed}

      assert NodeConnections.current(context.node.id) == nil
      assert NodeConnections.ready(context.node.id) == {:error, :temporarily_unavailable}
      assert NodeConnections.connection_pid(context.node.id) == nil

      assert_receive {:owner_closed, ^owner, :control_lost, nil}, 2_000
      assert AccessHarness.closed?(attach)
      assert AccessHarness.registered_keys(owner) == []

      AccessHarness.wait_until(fn ->
        Registry.lookup(Biot.Server.Control.Registry, context.node.id) == []
      end)

      # The same node reconnects, and the same process admits again on the new connection.
      peer =
        AccessHarness.ready_peer(context.listener_port, context.certificates, context.node, 0)

      %{stream: next} = admit_through_peer(peer, owner, shell(authentication, context.biot))
      refute next.connection_pid == connection_pid
    end
  end

  describe "one process, several admissions in turn" do
    test "admit, close, and admit again in one process", context do
      {_token, authentication} = AccessHarness.control(context.collaborator)
      {:control, digest, _expires_at} = authentication.proof
      owner = Owner.start()

      %{attach: first_attach} =
        admit_through_peer(context.peer, owner, shell(authentication, context.biot))

      Owner.close(owner)
      assert_receive {:owner_closed, ^owner, :by_owner, nil}
      assert AccessHarness.closed?(first_attach)
      assert AccessHarness.registered_keys(owner) == []

      AccessHarness.view_grant(context.biot, context.port, context.collaborator)

      %{stream: second} =
        admit_through_peer(context.peer, owner, preview(authentication, context.hostname))

      assert Enum.sort(AccessHarness.registered_keys(owner)) ==
               Enum.sort([
                 {:biot, context.biot.id},
                 {:principal, context.collaborator.id},
                 {:control_session, digest},
                 {:admitted, second.id}
               ])

      :ok = Owners.close_biot(context.biot.id)
      assert_receive {:owner_closed, ^owner, :policy, _observed}
      refute_receive {:owner_closed, ^owner, _reason, _observed}, 300
    end

    test "a close sent before the owner closed for its own reason does not deny the next admission",
         context do
      {_token, authentication} = AccessHarness.control(context.collaborator)
      owner = Owner.start()
      admit_through_peer(context.peer, owner, shell(authentication, context.biot))

      # The owner handles its own close first; the withdrawal's close was dispatched while the
      # owner was still registered, so it waits in the mailbox behind it.
      :erlang.suspend_process(owner)
      Owner.close(owner)
      :ok = Owners.close_biot(context.biot.id)
      :erlang.resume_process(owner)
      assert_receive {:owner_closed, ^owner, :by_owner, nil}

      %{stream: stream} =
        admit_through_peer(context.peer, owner, shell(authentication, context.biot))

      assert stream.kind == :shell
      refute_receive {:owner_closed, ^owner, _reason, _observed}, 300
    end

    test "two closes for one admission close it once and do not deny the next admission",
         context do
      {_token, authentication} = AccessHarness.control(context.collaborator)
      owner = Owner.start()
      admit_through_peer(context.peer, owner, shell(authentication, context.biot))

      :erlang.suspend_process(owner)
      :ok = Owners.close({:principal, context.collaborator.id})
      :ok = Owners.close_biot(context.biot.id)
      :erlang.resume_process(owner)
      assert_receive {:owner_closed, ^owner, :policy, _observed}

      admit_through_peer(context.peer, owner, shell(authentication, context.biot))
      refute_receive {:owner_closed, ^owner, _reason, _observed}, 300
    end

    test "the first admission's expiry does not close the second", context do
      {_token, short} = AccessHarness.control(context.collaborator)
      {:control, digest, _expires_at} = short.proof
      set_session_expiry(digest, DateTime.add(DateTime.utc_now(), 400, :millisecond))
      owner = Owner.start()
      admit_through_peer(context.peer, owner, shell(short, context.biot))
      Owner.close(owner)
      assert_receive {:owner_closed, ^owner, :by_owner, nil}

      admit_through_peer(
        context.peer,
        owner,
        shell(ssh_authentication(context.collaborator), context.biot)
      )

      refute_receive {:owner_closed, ^owner, _reason, _observed}, 800
    end

    test "two admissions on one connection report one control loss", context do
      {_token, authentication} = AccessHarness.control(context.collaborator)
      owner = Owner.start()
      admit_through_peer(context.peer, owner, shell(authentication, context.biot))
      Owner.close(owner)
      assert_receive {:owner_closed, ^owner, :by_owner, nil}

      %{stream: stream} =
        admit_through_peer(context.peer, owner, shell(authentication, context.biot))

      Process.exit(stream.connection_pid, :kill)
      assert_receive {:owner_closed, ^owner, :control_lost, nil}, 2_000
      refute_receive {:owner_closed, ^owner, _reason, _observed}, 300
    end
  end

  defp admit_through_peer(peer, owner, admission) do
    Owner.admit(owner, admission)
    open = AccessHarness.await_open(peer)
    attach = AccessHarness.attach(peer, open.stream_id)
    assert {:ok, %Stream{} = stream} = Owner.await_admitted(owner)
    %{open: open, attach: attach, stream: stream}
  end

  # The test process is the owner here, so after a denial it must hold no key, and no close
  # reaches it through any key it would have held.
  defp assert_denied(context, admission, expected, label \\ "") do
    assert admission.() == {:error, expected}, label
    AccessHarness.no_message(context.peer, Biot.Protocol.Message.OpenStream, 150)
    assert AccessHarness.registered_keys(self()) == [], label
    :ok = Owners.close_biot(context.biot.id)
    refute_received {:biot_access, :close}, label
  end

  defp shell(authentication, biot),
    do: fn -> Access.open_shell(authentication, biot.id, @shell) end

  defp preview(authentication, hostname),
    do: fn -> Access.open_preview(authentication, hostname) end

  defp preview_authentication(principal, hostname, parent_expires_at, preview_expires_at) do
    {_token, control} = AccessHarness.control(principal)
    {:control, parent_digest, _expires_at} = control.proof
    set_session_expiry(parent_digest, parent_expires_at)
    {token, preview_digest} = Tokens.mint()

    Repo.insert!(%Session{
      id_digest: preview_digest,
      principal_id: principal.id,
      scope: :preview,
      hostname: hostname,
      control_session_digest: parent_digest,
      expires_at: preview_expires_at
    })

    {:ok, authentication} = Sessions.preview(hostname, token)
    {preview_digest, parent_digest, authentication}
  end

  defp credential_authentication(principal) do
    {_token, control} = AccessHarness.control(principal)
    {:ok, created} = Credentials.create(control, "admission", hours(1))
    {:ok, authentication} = Credentials.authenticate(created.token)
    authentication
  end

  defp ssh_authentication(principal) do
    actor = %Actor{principal_id: principal.id}

    case Repo.get_by(SshKey, principal_id: principal.id) do
      nil -> {:ok, _view} = SshKeys.add(actor, @ssh_key, "admission")
      %SshKey{} -> :ok
    end

    {:ok, public_key} = SshPublicKey.parse(@ssh_key)
    {:ok, authentication} = SshKeys.authenticate(public_key)
    authentication
  end

  defp set_session_expiry(digest, expires_at) do
    {1, _} =
      Repo.update_all(from(s in Session, where: s.id_digest == ^digest),
        set: [expires_at: expires_at]
      )

    :ok
  end

  defp bump_access_revision(biot) do
    {1, _} =
      Repo.update_all(from(b in BiotRow, where: b.id == ^biot.id), inc: [access_revision: 1])

    :ok
  end

  defp hours(count), do: DateTime.add(DateTime.utc_now(), count * 3_600, :second)
end
