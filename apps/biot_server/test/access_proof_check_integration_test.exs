defmodule Biot.Server.AccessProofCheckIntegrationTest do
  @moduledoc false
  use Biot.Server.DataCase, async: false

  import Ecto.Query

  alias Biot.Protocol.{BiotId, SshPublicKey}
  alias Biot.Server.Access.Admission
  alias Biot.Server.Access.AuthSweep
  alias Biot.Server.Access.Owners
  alias Biot.Server.AccessHarness
  alias Biot.Server.AccessHarness.Registered
  alias Biot.Server.Actor
  alias Biot.Server.Credentials
  alias Biot.Server.Id
  alias Biot.Server.Schema.{Credential, Principal, Session, SshKey}
  alias Biot.Server.Sessions
  alias Biot.Server.SshKeys
  alias Biot.Server.TestFixtures
  alias Biot.Server.Tokens

  setup do
    owner = TestFixtures.principal(1)
    other = TestFixtures.principal(2)
    node = TestFixtures.node(1)
    {biot, _environment} = TestFixtures.biot(owner, node, 1)
    %{owner: owner, other: other, biot: biot}
  end

  test "the check closes exactly the owners whose proofs are no longer valid", context do
    {_token, valid_control} = AccessHarness.control(context.owner)
    {_token, deleted_control} = AccessHarness.control(context.owner)
    {_token, expired_control} = AccessHarness.control(context.owner)
    valid_credential = credential_authentication(context.owner)
    expired_credential = credential_authentication(context.owner)
    valid_ssh = ssh_authentication(context.owner)
    removed_ssh = ssh_authentication(context.owner)

    {_token, live_parent} = AccessHarness.control(context.owner)
    valid_preview = preview_authentication(context.owner, digest(live_parent), hours(1))
    expired_preview = preview_authentication(context.owner, digest(live_parent), hours(1))
    {_token, ended_parent} = AccessHarness.control(context.owner)
    orphaned_preview = preview_authentication(context.owner, digest(ended_parent), hours(1))

    valid =
      for authentication <- [valid_control, valid_credential, valid_ssh, valid_preview],
          do: Registered.start(context.biot.id, authentication)

    invalid =
      for authentication <- [
            deleted_control,
            expired_control,
            expired_credential,
            removed_ssh,
            expired_preview,
            orphaned_preview
          ],
          do: Registered.start(context.biot.id, authentication)

    # The deletes and expiries below bypass every closing command, as a lost notice would.
    delete_session(digest(deleted_control))
    expire_session(digest(expired_control))
    expire_session(preview_digest(expired_preview))
    delete_session(digest(ended_parent))
    {:credential, credential_id, _expires_at} = expired_credential.proof
    expire_credential(credential_id)
    {:ssh_key, key_id} = removed_ssh.proof
    Repo.delete_all(from(k in SshKey, where: k.id == ^key_id))

    assert :ok = Admission.close_invalid_proof_owners()

    for pid <- invalid, do: assert_receive({:closed, ^pid, nil})
    for pid <- valid, do: refute_receive({:closed, ^pid, _observed}, 100)
  end

  test "a principal disabled only in the database loses every live owner at the next check",
       context do
    {_token, control} = AccessHarness.control(context.other)
    credential = credential_authentication(context.other)
    ssh = ssh_authentication(context.other)
    {_token, bystander} = AccessHarness.control(context.owner)

    disabled =
      for authentication <- [control, credential, ssh],
          do: Registered.start(context.biot.id, authentication)

    kept = Registered.start(context.biot.id, bystander)

    Repo.update_all(from(p in Principal, where: p.id == ^context.other.id),
      set: [status: :disabled]
    )

    assert :ok = Admission.close_invalid_proof_owners()

    for pid <- disabled, do: assert_receive({:closed, ^pid, nil})
    refute_receive {:closed, ^kept, _observed}, 100
  end

  test "the registry reports each distinct proof key once and no closure-only key", context do
    {_token, control} = AccessHarness.control(context.owner)
    preview = preview_authentication(context.owner, digest(control), hours(1))
    _first = Registered.start(context.biot.id, control)
    _second = Registered.start(context.biot.id, control)
    _preview = Registered.start(Id.generate(BiotId), preview)

    assert Enum.sort(Owners.proof_keys()) ==
             Enum.sort([
               {:control_session, digest(control)},
               {:preview_session, preview_digest(preview)}
             ])
  end

  describe "the periodic check" do
    setup do
      previous = Application.get_env(:biot_server, :auth_check_interval_ms)
      Application.put_env(:biot_server, :auth_check_interval_ms, 100)
      on_exit(fn -> Application.put_env(:biot_server, :auth_check_interval_ms, previous) end)
      :ok
    end

    test "a lost logout notice closes the owner within one interval, and a valid owner stays",
         context do
      sweep = start_supervised!(AuthSweep)
      {_token, lost} = AccessHarness.control(context.owner)
      {_token, valid} = AccessHarness.control(context.owner)
      lost_owner = Registered.start(context.biot.id, lost)
      valid_owner = Registered.start(context.biot.id, valid)

      deleted_at = System.monotonic_time(:millisecond)
      delete_session(digest(lost))

      assert_receive {:closed, ^lost_owner, nil}, 1_000
      assert System.monotonic_time(:millisecond) - deleted_at < 400
      refute_receive {:closed, ^valid_owner, _observed}, 350
      assert Process.alive?(sweep)
    end

    test "an expired session closes its owner at the next check", context do
      _sweep = start_supervised!(AuthSweep)
      {_token, expiring} = AccessHarness.control(context.owner)
      owner = Registered.start(context.biot.id, expiring)
      expire_session(digest(expiring))
      assert_receive {:closed, ^owner, nil}, 1_000
    end
  end

  test "a nil interval starts no check" do
    previous = Application.get_env(:biot_server, :auth_check_interval_ms)
    Application.put_env(:biot_server, :auth_check_interval_ms, nil)
    on_exit(fn -> Application.put_env(:biot_server, :auth_check_interval_ms, previous) end)
    assert AuthSweep.start_link([]) == :ignore
  end

  defp digest(authentication) do
    {:control, digest, _expires_at} = authentication.proof
    digest
  end

  defp preview_digest(authentication) do
    {:preview, digest, _parent, _hostname, _expires_at} = authentication.proof
    digest
  end

  defp preview_authentication(principal, parent_digest, expires_at) do
    {token, digest} = Tokens.mint()

    Repo.insert!(%Session{
      id_digest: digest,
      principal_id: principal.id,
      scope: :preview,
      hostname: TestFixtures.hostname(1),
      control_session_digest: parent_digest,
      expires_at: expires_at
    })

    {:ok, authentication} = Sessions.preview(TestFixtures.hostname(1), token)
    authentication
  end

  defp credential_authentication(principal) do
    {_token, control} = AccessHarness.control(principal)
    {:ok, created} = Credentials.create(control, "check", hours(1))
    {:ok, authentication} = Credentials.authenticate(created.token)
    authentication
  end

  defp ssh_authentication(principal) do
    {public, _private} = :crypto.generate_key(:eddsa, :ed25519)
    blob = <<11::32, "ssh-ed25519", byte_size(public)::32, public::binary>>
    line = "ssh-ed25519 " <> Base.encode64(blob)
    {:ok, _view} = SshKeys.add(%Actor{principal_id: principal.id}, line, "check")
    {:ok, public_key} = SshPublicKey.parse(line)
    {:ok, authentication} = SshKeys.authenticate(public_key)
    authentication
  end

  defp delete_session(digest),
    do: Repo.delete_all(from(s in Session, where: s.id_digest == ^digest))

  defp expire_session(digest) do
    Repo.update_all(from(s in Session, where: s.id_digest == ^digest),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )
  end

  defp expire_credential(credential_id) do
    Repo.update_all(from(c in Credential, where: c.id == ^credential_id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )
  end

  defp hours(count), do: DateTime.add(DateTime.utc_now(), count * 3_600, :second)
end
